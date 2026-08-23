#!/usr/bin/env python3
"""
analyze-watermarks.py — Phase 0 telemetry analyzer for compaction watermark tuning.

Reads JSONL request logs written by the qwen-compact proxy
(proxy/src/jsonl-logger.js) under ~/.cache/qwen-compact/logs/*.jsonl,
reconstructs context-utilization curves per inferred session, and reports
how each candidate watermark (50/60/70/75/80%) would have behaved.

Usage:
    scripts/analyze-watermarks.py [--logs GLOB] [--n-ctx N]
                                  [--session-gap-min MIN] [--csv]

Stdlib only. Read-only against telemetry files.

See docs/watermark-tuning.md. The initial 70% candidate should be replaced by
local telemetry once enough normal sessions have been recorded.
"""
from __future__ import annotations

import argparse
import csv
import glob
import json
import os
import sys
from datetime import datetime, timezone
from typing import Iterable

DEFAULT_LOGS = os.path.expanduser("~/.cache/qwen-compact/logs/*.jsonl")
DEFAULT_N_CTX = 262144  # Qwen3.8 native context; override with --n-ctx
DEFAULT_SESSION_GAP_MIN = 15  # inactivity gap that ends a session
WATERMARKS = (0.50, 0.60, 0.70, 0.75, 0.80)
# A session is considered to have "filled" the window if utilization ever
# crossed this very-high threshold (i.e. we really would have wanted to compact).
FILL_THRESHOLD = 0.90


def parse_ts(s: str) -> datetime | None:
    if not s:
        return None
    try:
        # Python <3.11 doesn't accept trailing 'Z'.
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        return datetime.fromisoformat(s)
    except ValueError:
        return None


def iter_records(paths: list[str]) -> Iterable[dict]:
    for p in paths:
        try:
            with open(p, "r", encoding="utf-8") as f:
                for ln, line in enumerate(f, 1):
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        yield json.loads(line)
                    except json.JSONDecodeError:
                        # Skip malformed lines but keep going — telemetry is
                        # append-only and the tail can be partial.
                        print(
                            f"warn: skipping malformed JSONL at {p}:{ln}",
                            file=sys.stderr,
                        )
        except OSError as e:
            print(f"warn: cannot read {p}: {e}", file=sys.stderr)


def pick_tokens(rec: dict) -> int | None:
    """Effective prompt size for utilization: prefer upstream prompt_tokens,
    fall back to the rewrite.orig_tokens, finally rewritten_tokens."""
    for k in ("prompt_tokens", "rewritten_tokens"):
        v = rec.get(k)
        if isinstance(v, int) and v >= 0:
            return v
    rw = rec.get("rewrite")
    if isinstance(rw, dict):
        for k in ("orig_tokens", "rewritten_tokens"):
            v = rw.get(k)
            if isinstance(v, int) and v >= 0:
                return v
    return None


def group_sessions(records: list[dict], gap_minutes: int) -> list[list[dict]]:
    """Sort records by timestamp, split on inactivity gap. The proxy doesn't
    persist a session id, so this is the best heuristic available."""
    enriched = []
    for r in records:
        ts = parse_ts(r.get("timestamp", ""))
        if ts is None:
            continue
        toks = pick_tokens(r)
        if toks is None:
            continue
        enriched.append((ts, toks, r))
    enriched.sort(key=lambda t: t[0])

    sessions: list[list[dict]] = []
    cur: list[dict] = []
    last_ts: datetime | None = None
    gap = gap_minutes * 60.0
    for ts, toks, r in enriched:
        rec = {"ts": ts, "tokens": toks, "raw": r}
        if last_ts is not None and (ts - last_ts).total_seconds() > gap:
            if cur:
                sessions.append(cur)
            cur = []
        cur.append(rec)
        last_ts = ts
    if cur:
        sessions.append(cur)
    return sessions


def analyze(sessions: list[list[dict]], n_ctx: int) -> dict:
    """For each candidate watermark, compute trigger count, average lead time
    (in messages before the session's max-utilization request), and
    false-positive rate (triggered but session never crossed FILL_THRESHOLD)."""
    total = len(sessions)
    per_session_max_ratio: list[float] = []
    # Index in session of first request that crossed each watermark.
    trigger_idx: dict[float, list[int | None]] = {w: [] for w in WATERMARKS}
    # Index of peak-utilization request per session.
    peak_idx: list[int] = []
    filled_flags: list[bool] = []

    for sess in sessions:
        ratios = [min(1.0, r["tokens"] / n_ctx) if n_ctx > 0 else 0.0 for r in sess]
        if not ratios:
            continue
        peak = max(range(len(ratios)), key=lambda i: ratios[i])
        peak_idx.append(peak)
        per_session_max_ratio.append(ratios[peak])
        filled_flags.append(ratios[peak] >= FILL_THRESHOLD)
        for w in WATERMARKS:
            first = next((i for i, r in enumerate(ratios) if r >= w), None)
            trigger_idx[w].append(first)

    rows = []
    for w in WATERMARKS:
        triggered = [i for i in trigger_idx[w] if i is not None]
        triggers = len(triggered)
        # Lead time: messages between first-trigger and peak in the same session.
        leads = [
            peak_idx[s] - i
            for s, i in enumerate(trigger_idx[w])
            if i is not None and peak_idx[s] >= i
        ]
        avg_lead = sum(leads) / len(leads) if leads else 0.0
        # False positive: triggered but never actually filled the window.
        fp = sum(
            1
            for s, i in enumerate(trigger_idx[w])
            if i is not None and not filled_flags[s]
        )
        fp_rate = (fp / triggers) if triggers else 0.0
        rows.append(
            {
                "watermark": w,
                "sessions_triggered": triggers,
                "trigger_rate": (triggers / total) if total else 0.0,
                "avg_lead_messages": avg_lead,
                "false_positives": fp,
                "false_positive_rate": fp_rate,
            }
        )

    return {
        "total_sessions": total,
        "sessions_filled": sum(filled_flags),
        "rows": rows,
        "per_session_max_ratio": per_session_max_ratio,
    }


def suggest(report: dict) -> tuple[float, str]:
    """Pick the watermark with the best lead-time / false-positive tradeoff:
    among watermarks that triggered on >=50% of sessions that actually filled,
    choose the lowest false-positive rate; tiebreak on largest avg lead."""
    rows = report["rows"]
    filled = report["sessions_filled"]
    if filled == 0:
        return 0.70, "no sessions filled the window — keeping the default 70%"
    # Score: minimize FPR, maximize lead.
    candidates = [r for r in rows if r["sessions_triggered"] > 0]
    if not candidates:
        return 0.70, "no candidate triggered — keeping default 70%"
    best = min(
        candidates,
        key=lambda r: (r["false_positive_rate"], -r["avg_lead_messages"]),
    )
    return (
        best["watermark"],
        f"lowest false-positive rate ({best['false_positive_rate']:.0%}) "
        f"with {best['avg_lead_messages']:.1f}-message average lead",
    )


def render_markdown(report: dict, n_ctx: int, suggested: tuple[float, str]) -> str:
    lines = []
    lines.append("# Watermark analysis (Phase 0 telemetry)")
    lines.append("")
    lines.append(f"- Sessions analyzed: **{report['total_sessions']}**")
    lines.append(
        f"- Sessions that crossed {FILL_THRESHOLD:.0%} utilization "
        f"(\"filled\"): **{report['sessions_filled']}**"
    )
    lines.append(f"- Assumed n_ctx: **{n_ctx}**")
    lines.append("")
    lines.append(
        "| Watermark | Sessions triggered | Trigger rate | "
        "Avg lead (msgs) | False positives | FPR |"
    )
    lines.append("|-----------|-------------------:|-------------:|"
                 "----------------:|----------------:|----:|")
    for r in report["rows"]:
        lines.append(
            f"| {r['watermark']:.0%} | {r['sessions_triggered']} | "
            f"{r['trigger_rate']:.0%} | {r['avg_lead_messages']:.1f} | "
            f"{r['false_positives']} | {r['false_positive_rate']:.0%} |"
        )
    lines.append("")
    w, why = suggested
    lines.append(f"**Suggested watermark: {w:.0%}** — {why}.")
    lines.append("")
    return "\n".join(lines)


def render_csv(report: dict, n_ctx: int, suggested: tuple[float, str]) -> str:
    import io

    buf = io.StringIO()
    wr = csv.writer(buf)
    wr.writerow(
        [
            "watermark",
            "sessions_triggered",
            "trigger_rate",
            "avg_lead_messages",
            "false_positives",
            "false_positive_rate",
            "total_sessions",
            "sessions_filled",
            "n_ctx",
            "suggested_watermark",
        ]
    )
    sw, _ = suggested
    for r in report["rows"]:
        wr.writerow(
            [
                f"{r['watermark']:.2f}",
                r["sessions_triggered"],
                f"{r['trigger_rate']:.4f}",
                f"{r['avg_lead_messages']:.2f}",
                r["false_positives"],
                f"{r['false_positive_rate']:.4f}",
                report["total_sessions"],
                report["sessions_filled"],
                n_ctx,
                f"{sw:.2f}",
            ]
        )
    return buf.getvalue()


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description="Analyze Phase 0 telemetry and recommend a compaction watermark.",
    )
    p.add_argument(
        "--logs",
        default=DEFAULT_LOGS,
        help=f"glob for JSONL telemetry files (default: {DEFAULT_LOGS})",
    )
    p.add_argument(
        "--n-ctx",
        type=int,
        default=DEFAULT_N_CTX,
        help=f"upstream slot context size in tokens (default: {DEFAULT_N_CTX})",
    )
    p.add_argument(
        "--session-gap-min",
        type=int,
        default=DEFAULT_SESSION_GAP_MIN,
        help=(
            "inactivity gap (minutes) used to split sessions; the proxy does "
            f"not record a session id (default: {DEFAULT_SESSION_GAP_MIN})"
        ),
    )
    p.add_argument(
        "--csv",
        action="store_true",
        help="emit CSV instead of Markdown",
    )
    args = p.parse_args(argv)

    paths = sorted(glob.glob(os.path.expanduser(args.logs)))
    if not paths:
        print(
            f"no jsonl files found at {args.logs}; run the proxy in shadow "
            f"mode for a week first",
            file=sys.stderr,
        )
        return 1

    records = list(iter_records(paths))
    if not records:
        print(
            f"no usable JSONL records in {len(paths)} file(s) at {args.logs}; "
            f"run the proxy in shadow mode for a week first",
            file=sys.stderr,
        )
        return 1

    sessions = group_sessions(records, args.session_gap_min)
    if not sessions:
        print(
            "no records had usable timestamps + token counts; nothing to analyze",
            file=sys.stderr,
        )
        return 1

    report = analyze(sessions, args.n_ctx)
    suggestion = suggest(report)
    out = (
        render_csv(report, args.n_ctx, suggestion)
        if args.csv
        else render_markdown(report, args.n_ctx, suggestion)
    )
    sys.stdout.write(out)
    if not args.csv and not out.endswith("\n"):
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
