#!/usr/bin/env python3
"""runner.py — A/B harness driver.

Iterates the (variant x seed x fixture) matrix and writes one JSON file per
variant under --output. Each cell is computed by invoking the Node CLI shim
`proxy/scripts/run-rewrite.js`, which runs the proxy's `rewriteRequest()`
in-process against the fixture without any HTTP / tokenizer service.

Conventions:
  - stdlib only (argparse, json, os, re, subprocess, sys, time, pathlib)
  - no pytest
  - no network calls
  - exit 0 on a clean run; non-zero on usage / IO errors

Hook engine status: the sibling task implementing proxy/src/hooks/ is in
flight. Until it lands, the `tier1+hooks` variant in the shim falls through
to `tier1-only` behavior; the aggregator footnotes this explicitly.

Usage:
    python3 runner.py \\
        --fixture fixtures/tool-heavy.jsonl \\
        --variants do-nothing,tier0+tier1 \\
        --seeds 1 \\
        --output ./out

    # All fixtures × all variants (smoke):
    python3 runner.py --all --seeds 1 --output ./out
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import variants as _variants  # noqa: E402

# Repo root is three levels up from this file:
#   <repo>/proxy/eval/ab-harness/runner.py
_REPO = _HERE.parent.parent.parent
_SHIM = _REPO / "proxy" / "scripts" / "run-rewrite.js"
_FIXTURES_DIR = _HERE / "fixtures"


METRIC_KEYS = (
    "variant",
    "seed",
    "fixture",
    "prompt_tokens",
    "rewritten_tokens",
    "completion_tokens",
    "latency_ms",
    "needle_recovery",
    "decision_preservation",
    "turns_completed",
    "error",
)


# Per-fixture needle text (the assertion is "this exact substring survives").
# Tracks the NEEDLE[<id>] markers baked into the fixtures.
NEEDLE_FACTS: dict[str, str] = {
    "tool-heavy.jsonl": "retry_backoff_ms=4500",
    "chit-chat.jsonl": "Lumen-on-Ash",
    "decision-heavy.jsonl": "rb-2026-05-07-T1",
    "code-review.jsonl": "ruff reported zero violations",
    "mixed-prose-tool.jsonl": "14.7 percent",
}


def _grade_needle(text: str, fixture_basename: str) -> float:
    needle = NEEDLE_FACTS.get(fixture_basename)
    if not needle:
        return 0.0
    return 1.0 if needle in text else 0.0


def _grade_decisions(text: str, original_text: str) -> float:
    """Fraction of AGREED [D-NN] / [CR-NN] / [MX-NN] markers that survived."""
    pat = re.compile(r"AGREED \[(?:D|CR|MX)-\d+\]")
    orig = set(pat.findall(original_text))
    if not orig:
        return 1.0  # no decisions in this fixture — vacuously preserved
    kept = set(pat.findall(text))
    return len(orig & kept) / len(orig)


def _read_fixture_text(path: Path) -> str:
    parts: list[str] = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            c = row.get("content")
            if isinstance(c, str):
                parts.append(c)
            elif isinstance(c, list):
                for p in c:
                    if isinstance(p, dict):
                        if isinstance(p.get("text"), str):
                            parts.append(p["text"])
                        elif isinstance(p.get("content"), str):
                            parts.append(p["content"])
    return "\n".join(parts)


def run_one(variant: _variants.Variant, fixture: str, seed: int) -> dict[str, Any]:
    """Execute a single (variant, fixture, seed) cell via the Node shim."""
    fixture_path = Path(fixture)
    fixture_basename = fixture_path.name

    cmd = [
        "node",
        str(_SHIM),
        "--fixture",
        str(fixture_path),
        "--variant",
        variant.id,
    ]

    t0 = time.time()
    err: str | None = None
    shim: dict[str, Any] = {}
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=60,
            cwd=str(_REPO),
        )
        if proc.returncode != 0:
            err = (
                f"shim exit {proc.returncode}: "
                f"{(proc.stderr or '').strip()[:400]}"
            )
        else:
            # Last non-empty line of stdout is the JSON record.
            lines = [ln for ln in proc.stdout.splitlines() if ln.strip()]
            if not lines:
                err = "shim produced no stdout"
            else:
                shim = json.loads(lines[-1])
    except subprocess.TimeoutExpired:
        err = "shim timeout"
    except Exception as e:  # noqa: BLE001
        err = f"{type(e).__name__}: {e}"
    elapsed_ms = int((time.time() - t0) * 1000)

    text_out = shim.get("text", "") if not err else ""
    original_text = _read_fixture_text(fixture_path)

    return {
        "variant": variant.id,
        "seed": seed,
        "fixture": fixture_basename,
        "prompt_tokens": int(shim.get("prompt_tokens", 0) or 0),
        "rewritten_tokens": int(shim.get("rewritten_tokens", 0) or 0),
        "completion_tokens": int(shim.get("completion_tokens", 0) or 0),
        # Prefer the shim's measured rewrite latency; fall back to wall time.
        "latency_ms": int(shim.get("latency_ms", elapsed_ms) or elapsed_ms),
        "needle_recovery": _grade_needle(text_out, fixture_basename) if not err else 0.0,
        "decision_preservation": _grade_decisions(text_out, original_text) if not err else 0.0,
        "turns_completed": int(shim.get("turns_completed", 0) or 0),
        "error": err or shim.get("error"),
    }


def _parse_variants(arg: str) -> list[_variants.Variant]:
    ids = [v.strip() for v in arg.split(",") if v.strip()]
    if not ids:
        raise ValueError("--variants must list at least one id")
    return [_variants.get(v) for v in ids]


def _parse_fixtures(arg: str | None, all_flag: bool) -> list[Path]:
    if all_flag:
        return sorted(p for p in _FIXTURES_DIR.glob("*.jsonl") if not p.name.startswith("_"))
    if not arg:
        raise ValueError("either --fixture or --all is required")
    paths = []
    for f in arg.split(","):
        f = f.strip()
        if not f:
            continue
        p = Path(f)
        if not p.is_absolute() and not p.exists():
            # try relative to fixtures dir
            cand = _FIXTURES_DIR / f
            if cand.exists():
                p = cand
        paths.append(p)
    return paths


def _write_results(out_dir: Path, variant_id: str, rows: list[dict[str, Any]]) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{variant_id}.json"
    with open(path, "w", encoding="utf-8") as f:
        json.dump(rows, f, indent=2)
    return path


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="A/B harness for proxy compaction variants.",
    )
    ap.add_argument("--fixture", help="Fixture path (or comma-list). Use --all to run them all.")
    ap.add_argument("--all", action="store_true", help="Run against every fixture in fixtures/.")
    ap.add_argument("--variants", help="Comma-separated variant ids (default: all).")
    ap.add_argument("--seeds", type=int, default=1)
    ap.add_argument("--output", required=True)
    args = ap.parse_args(argv)

    if args.seeds < 1:
        print("--seeds must be >= 1", file=sys.stderr)
        return 2

    try:
        chosen = _parse_variants(args.variants) if args.variants else [
            _variants.get(v) for v in _variants.all_ids()
        ]
        fixtures = _parse_fixtures(args.fixture, args.all)
    except (ValueError, KeyError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    if not fixtures:
        print("no fixtures resolved", file=sys.stderr)
        return 2

    if not _SHIM.exists():
        print(f"warning: shim not found at {_SHIM}", file=sys.stderr)

    out_dir = Path(args.output)
    t0 = time.time()
    total_cells = 0

    for variant in chosen:
        rows: list[dict[str, Any]] = []
        for fixture_path in fixtures:
            for seed in range(args.seeds):
                metrics = run_one(variant, str(fixture_path), seed)
                assert set(metrics.keys()) == set(METRIC_KEYS), (
                    f"run_one returned unexpected keys: {sorted(metrics.keys())}"
                )
                rows.append(metrics)
                total_cells += 1
                tag = "ok" if not metrics.get("error") else f"ERR:{metrics['error'][:60]}"
                print(
                    f"[{variant.id:22s}] {fixture_path.name:24s} seed={seed} "
                    f"orig={metrics['prompt_tokens']:>6d} "
                    f"rewr={metrics['rewritten_tokens']:>6d} "
                    f"needle={metrics['needle_recovery']:.0f} "
                    f"agreed={metrics['decision_preservation']:.2f} {tag}"
                )
        path = _write_results(out_dir, variant.id, rows)
        print(f"[{variant.id}] wrote {len(rows)} rows -> {path}")

    elapsed = time.time() - t0
    print()
    print(f"matrix: {len(chosen)} variants x {len(fixtures)} fixtures x {args.seeds} seeds = {total_cells} cells")
    print(f"elapsed: {elapsed:.2f}s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
