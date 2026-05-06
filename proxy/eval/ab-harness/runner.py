#!/usr/bin/env python3
"""runner.py — A/B harness scaffold.

This is a SCAFFOLD. It iterates the (variant x seed) matrix and writes one
JSON file per variant under --output, but every cell currently contains
stub metrics. Real measurement lands in subsequent tasks (see README).

Conventions follow proxy/eval/replay.py and proxy/eval/run_smoke.sh:
  - stdlib only (argparse, json, os, sys, time, pathlib)
  - no pytest dependency
  - no network calls in the scaffold (offline-mode safe)
  - exit 0 on a clean run; non-zero on usage / IO errors

Usage:
    python3 runner.py --fixture fixtures/needle_50turns.jsonl \\
                      --variants do-nothing,tier0+tier1 \\
                      --seeds 3 \\
                      --output ./out

Next-step pointers (DO NOT implement here — separate tasks):
  - #23: wire run_one() to actually launch the proxy with the variant's
         proxy_config overrides (see variants.Variant.proxy_config) and
         drive it via proxy/eval/replay.py::replay_session().
  - #24: pull needle_recovery from proxy/eval/needle.py::verify after
         issuing a final recall turn against the live proxy.
  - #25: compute decision_preservation by diffing tool-call sequences
         between the rewritten and original messages.
  - #26: emit a cross-variant report (markdown + CSV) under output/.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any

# Local imports — kept relative to the harness directory so the script works
# whether invoked as `python3 runner.py` or `python3 -m ab_harness.runner`.
_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import variants as _variants  # noqa: E402


# Stub metric shape ----------------------------------------------------------
#
# Every cell of the (variant x seed x fixture) matrix produces a dict with
# exactly these keys. Downstream report tooling will rely on this shape, so
# adding/removing keys here is a breaking change.
METRIC_KEYS = (
    "variant",
    "seed",
    "fixture",
    "prompt_tokens",
    "completion_tokens",
    "latency_ms",
    "needle_recovery",
    "decision_preservation",
    "turns_completed",
)


def run_one(variant: _variants.Variant, fixture: str, seed: int) -> dict[str, Any]:
    """Execute a single (variant, fixture, seed) cell.

    SCAFFOLD: returns stub metrics. The real implementation will:
      1. Patch proxy/config.yaml with `variant.proxy_config`.
      2. Boot the proxy (or reuse a running one and POST a config-reload).
      3. Replay `fixture` via proxy/eval/replay.py::replay_session,
         attaching `variant.client_headers` to each request.
      4. Issue the recall turn and grade with proxy/eval/needle.py.
      5. Tear down the proxy and collect timing + token counts.
    """
    # TODO(#23): wire to real proxy — see variants.proxy_config for the
    # config knobs each leg needs. Until then, return zeros so the matrix
    # plumbing can be exercised end-to-end.
    return {
        "variant": variant.id,
        "seed": seed,
        "fixture": fixture,
        "prompt_tokens": 0,
        "completion_tokens": 0,
        "latency_ms": 0,
        "needle_recovery": 0.0,
        "decision_preservation": 0.0,
        "turns_completed": 0,
    }


def _parse_variants(arg: str) -> list[_variants.Variant]:
    ids = [v.strip() for v in arg.split(",") if v.strip()]
    if not ids:
        raise ValueError("--variants must list at least one id")
    return [_variants.get(v) for v in ids]


def _write_results(out_dir: Path, variant_id: str, rows: list[dict[str, Any]]) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    # Filenames are derived from the variant id; ids are constrained to be
    # filesystem-safe in variants.py.
    path = out_dir / f"{variant_id}.json"
    with open(path, "w", encoding="utf-8") as f:
        json.dump(rows, f, indent=2)
    return path


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="A/B harness scaffold for proxy compaction variants.",
    )
    ap.add_argument(
        "--fixture",
        required=True,
        help="Path to a session JSONL fixture (see proxy/eval/needle.py generate).",
    )
    ap.add_argument(
        "--variants",
        required=True,
        help="Comma-separated variant ids (see variants.py::VARIANTS).",
    )
    ap.add_argument(
        "--seeds",
        type=int,
        default=1,
        help="Number of seeds per variant (default: 1).",
    )
    ap.add_argument(
        "--output",
        required=True,
        help="Directory to write per-variant JSON results into.",
    )
    args = ap.parse_args(argv)

    if not os.path.exists(args.fixture):
        # Scaffold tolerates a missing fixture for dry runs but warns loudly.
        print(f"warning: fixture not found: {args.fixture}", file=sys.stderr)

    if args.seeds < 1:
        print("--seeds must be >= 1", file=sys.stderr)
        return 2

    try:
        chosen = _parse_variants(args.variants)
    except (ValueError, KeyError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    out_dir = Path(args.output)
    t0 = time.time()
    total_cells = 0

    for variant in chosen:
        rows: list[dict[str, Any]] = []
        for seed in range(args.seeds):
            metrics = run_one(variant, args.fixture, seed)
            # Defensive: enforce the documented shape.
            assert set(metrics.keys()) == set(METRIC_KEYS), (
                f"run_one returned unexpected keys: {sorted(metrics.keys())}"
            )
            rows.append(metrics)
            total_cells += 1
        path = _write_results(out_dir, variant.id, rows)
        print(f"[{variant.id}] wrote {len(rows)} stub rows -> {path}")

    elapsed = time.time() - t0
    print()
    print(f"matrix: {len(chosen)} variants x {args.seeds} seeds = {total_cells} cells")
    print(f"elapsed: {elapsed:.2f}s")
    print()
    print("TODO: wire to real proxy")
    print("  - run_one() currently returns stub zeros; see #23 to plumb in")
    print("    proxy/eval/replay.py and the live proxy (proxy/config.yaml).")
    print("  - needle grading lands in #24 via proxy/eval/needle.py verify.")
    print("  - decision-preservation metric lands in #25.")
    print("  - cross-variant report generation lands in #26.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
