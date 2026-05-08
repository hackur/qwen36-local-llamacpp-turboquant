#!/usr/bin/env python3
"""aggregate.py — fold per-cell rows into the §11 metric shape.

Reads all `<variant>.json` files in a directory produced by `runner.py` and
emits two artifacts:

  1. A JSON aggregate (per fixture × variant) matching docs/hooks-middleware.md
     §11 ("Per-run metrics" block).
  2. A markdown table suitable for the "Battle test results" section of
     docs/hooks-middleware.md.

Usage:
    python3 aggregate.py --input ./out [--baseline tier0+tier1] \\
                         [--md-out table.md] [--json-out agg.json]

Stdlib only. Computes its own percentiles (no numpy).
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from typing import Any


def _percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    if len(s) == 1:
        return float(s[0])
    k = (len(s) - 1) * (pct / 100.0)
    lo = math.floor(k)
    hi = math.ceil(k)
    if lo == hi:
        return float(s[int(k)])
    return float(s[lo] + (s[hi] - s[lo]) * (k - lo))


def _load(in_dir: Path) -> dict[str, list[dict[str, Any]]]:
    out: dict[str, list[dict[str, Any]]] = {}
    for p in sorted(in_dir.glob("*.json")):
        rows = json.loads(p.read_text(encoding="utf-8"))
        if not isinstance(rows, list):
            continue
        # Variant id is the filename stem (matches what runner._write_results writes).
        vid = p.stem
        out[vid] = rows
    return out


def _aggregate(rows: list[dict[str, Any]]) -> dict[str, Any]:
    if not rows:
        return {}
    lat = [float(r.get("latency_ms", 0)) for r in rows]
    needle = [float(r.get("needle_recovery", 0)) for r in rows]
    orig_t = [float(r.get("prompt_tokens", 0)) for r in rows]
    rewr_t = [float(r.get("rewritten_tokens", 0)) for r in rows]
    errors = [1.0 if r.get("error") else 0.0 for r in rows]
    decisions = [float(r.get("decision_preservation", 0)) for r in rows]
    hook_times = [float(r.get("total_hook_time_ms") or 0) for r in rows]
    hook_err_rows = [
        1.0 if (r.get("hook_errors") or []) else 0.0 for r in rows
    ]

    orig_sum = sum(orig_t)
    rewr_sum = sum(rewr_t)
    token_red = (1.0 - rewr_sum / orig_sum) * 100.0 if orig_sum > 0 else 0.0

    return {
        "runs": len(rows),
        "needle_recall_pct": (sum(needle) / len(needle)) * 100.0,
        "decision_preservation_pct": (sum(decisions) / len(decisions)) * 100.0,
        "token_reduction_pct": token_red,
        "latency_p50_ms": _percentile(lat, 50),
        "latency_p99_ms": _percentile(lat, 99),
        # Hook timings populated when the shim runs through the hook engine
        # (variants with `hooks: true` in run-rewrite.js). Variants without
        # the engine surface 0.
        "total_hook_time_p50_ms": _percentile(hook_times, 50),
        "total_hook_time_p99_ms": _percentile(hook_times, 99),
        "hook_error_rate": sum(hook_err_rows) / len(hook_err_rows),
        "shim_error_rate": sum(errors) / len(errors),
        "hook_timeout_rate": 0.0,
    }


def _verdict(rec_pct: float, tok_red: float) -> str:
    if rec_pct < 90:
        return "needs work"
    if tok_red <= 0:
        return "no-op"
    if tok_red > 30 and rec_pct >= 95:
        return "ship"
    return "ok"


def _verdict_vs_baseline(
    rec_pct: float, tok_red: float, base_red: float, variant_id: str, baseline: str
) -> str:
    if rec_pct < 90:
        return "needs work"
    if variant_id == baseline:
        return "baseline"
    if tok_red <= 0 and base_red <= 0:
        return "no-op (both)"
    if tok_red <= 0 < base_red:
        return "loses to baseline"
    if tok_red > base_red + 1.0:
        return "beats baseline"
    if abs(tok_red - base_red) <= 1.0:
        return "matches baseline"
    return "ok"


def to_markdown(
    by_variant: dict[str, list[dict[str, Any]]],
    baseline: str = "tier0+tier1",
) -> str:
    """Render the §11 'Battle test results' table.

    One row per (variant, fixture). Token Δ % is the % reduction in
    rewritten-token count vs the original (raw) prompt: positive means the
    variant compressed the prompt; 0 means passthrough; negative would
    indicate the variant produced *more* tokens than raw (shouldn't happen
    in this scaffold). The `baseline` argument selects which variant the
    Verdict column compares against.
    """
    base_rows = {r["fixture"]: r for r in by_variant.get(baseline, [])}

    lines: list[str] = []
    lines.append("| Variant | Fixture | Recall % | Decision % | Token Δ % | p50 ms | p99 ms | Err % | Verdict |")
    lines.append("|---|---|---|---|---|---|---|---|---|")

    for variant_id in sorted(by_variant.keys()):
        rows = by_variant[variant_id]
        # group by fixture
        by_fix: dict[str, list[dict[str, Any]]] = {}
        for r in rows:
            by_fix.setdefault(r.get("fixture", "?"), []).append(r)

        for fixture in sorted(by_fix):
            agg = _aggregate(by_fix[fixture])
            # Token Δ % = reduction vs the raw prompt for THIS variant on
            # THIS fixture. (do-nothing reads 0 by construction.)
            tok_delta = agg["token_reduction_pct"]

            # Verdict compares this variant's recall + reduction against
            # baseline's reduction: a hook is "ship"-worthy if it preserves
            # recall AND beats baseline on tokens.
            base_rows_fix = [r for r in by_variant.get(baseline, []) if r.get("fixture") == fixture]
            base_orig = sum(r.get("prompt_tokens", 0) for r in base_rows_fix)
            base_rewr = sum(r.get("rewritten_tokens", 0) for r in base_rows_fix)
            base_red = (1.0 - base_rewr / base_orig) * 100.0 if base_orig else 0.0
            verdict = _verdict_vs_baseline(
                agg["needle_recall_pct"], tok_delta, base_red, variant_id, baseline
            )
            err_pct = agg.get("shim_error_rate", agg["hook_error_rate"]) * 100
            lines.append(
                f"| `{variant_id}` | `{fixture}` | "
                f"{agg['needle_recall_pct']:.0f} | "
                f"{agg['decision_preservation_pct']:.0f} | "
                f"{tok_delta:+.1f} | "
                f"{agg['latency_p50_ms']:.0f} | "
                f"{agg['latency_p99_ms']:.0f} | "
                f"{err_pct:.1f} | "
                f"{verdict} |"
            )

    lines.append("")
    lines.append(
        "Token Δ % = reduction in rewritten-token count vs the raw prompt for "
        "that variant × fixture (positive = compression). Verdict compares "
        f"each row against `{baseline}` token reduction on the same fixture."
    )
    lines.append("")
    lines.append(
        "`tier1+hooks` now routes through the hook engine "
        "(`proxy/src/hooks/`) via `proxy/scripts/run-rewrite.js`. The shim "
        "registers `context-pressure-reminder` at `request:before-rewrite` "
        "and `tag-bash-read-elisions` at `request:after-rewrite`; per-cell "
        "rows carry `hook_tags`, `hook_timings_ms`, `hook_errors`, and "
        "`total_hook_time_ms`."
    )
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True, help="Directory of <variant>.json result files.")
    ap.add_argument("--baseline", default="tier0+tier1")
    ap.add_argument("--md-out", help="Write markdown table here (else stdout).")
    ap.add_argument("--json-out", help="Write per-fixture aggregates here.")
    args = ap.parse_args(argv)

    in_dir = Path(args.input)
    if not in_dir.is_dir():
        print(f"error: {in_dir} is not a directory", file=sys.stderr)
        return 2

    by_variant = _load(in_dir)
    if not by_variant:
        print(f"error: no <variant>.json files in {in_dir}", file=sys.stderr)
        return 2

    md = to_markdown(by_variant, baseline=args.baseline)
    if args.md_out:
        Path(args.md_out).write_text(md + "\n", encoding="utf-8")
    else:
        print(md)

    if args.json_out:
        out: dict[str, dict[str, dict[str, Any]]] = {}
        for variant_id, rows in by_variant.items():
            by_fix: dict[str, list[dict[str, Any]]] = {}
            for r in rows:
                by_fix.setdefault(r.get("fixture", "?"), []).append(r)
            out[variant_id] = {fx: _aggregate(rs) for fx, rs in by_fix.items()}
        Path(args.json_out).write_text(json.dumps(out, indent=2), encoding="utf-8")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
