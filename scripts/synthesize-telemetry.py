#!/usr/bin/env python3
"""
synthesize-telemetry.py — generate realistic-shape synthetic JSONL telemetry
matching the schema written by proxy/src/jsonl-logger.js, for the purpose of
exercising scripts/analyze-watermarks.py end-to-end before a week of real
shadow-mode traffic exists.

Stdlib only. Deterministic via fixed --seed.

The synthesizer fabricates `--days` days of activity, with `--sessions-per-day`
sessions/day and 8-25 messages/session. prompt_tokens grow from a small seed
upward with per-message deltas and occasional plateaus, so different sessions
land in different regimes:

  - "short"   : never crosses 50% utilization (small chats).
  - "medium"  : crosses 60-70% then stops growing.
  - "filling" : steadily climbs and crosses 90% (the cases compaction must catch).
  - "burst"   : suddenly jumps from low-util to high-util (tool-heavy turns).

Output: JSONL, one record per request, fields chosen so the analyzer's
pick_tokens()/group_sessions() functions work as in production.

NOT written under ~/.cache/qwen-compact/logs/ to avoid polluting real telemetry.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone

DEFAULT_N_CTX = 32768
SESSION_GAP_MIN = 15  # must exceed analyzer's --session-gap-min
WITHIN_SESSION_GAP_S = (3.0, 90.0)   # seconds between consecutive messages
INTER_SESSION_GAP_MIN = (20, 240)    # minutes between sessions in same day

# Mix of session shapes. Weights chosen so a realistic share fills the window.
SHAPES = [
    ("short",   0.35),
    ("medium",  0.30),
    ("filling", 0.20),
    ("burst",   0.15),
]


def pick_shape(rng: random.Random) -> str:
    r = rng.random()
    acc = 0.0
    for name, w in SHAPES:
        acc += w
        if r <= acc:
            return name
    return SHAPES[-1][0]


def gen_session_tokens(rng: random.Random, shape: str, n_ctx: int) -> list[int]:
    n_msgs = rng.randint(8, 25)
    base = rng.randint(800, 2500)
    seq: list[int] = [base]
    if shape == "short":
        # Stays well under 50%: target peak 0.20-0.45.
        peak = int(n_ctx * rng.uniform(0.20, 0.45))
        step = max(1, (peak - base) // max(1, n_msgs - 1))
        for _ in range(n_msgs - 1):
            seq.append(seq[-1] + rng.randint(int(step * 0.4), int(step * 1.4)))
    elif shape == "medium":
        # Climbs into 0.55-0.78 then plateaus.
        peak = int(n_ctx * rng.uniform(0.55, 0.78))
        climb = rng.randint(max(1, n_msgs // 2), n_msgs - 2)
        step = max(1, (peak - base) // max(1, climb))
        for i in range(n_msgs - 1):
            if i < climb:
                seq.append(seq[-1] + rng.randint(int(step * 0.5), int(step * 1.3)))
            else:
                seq.append(seq[-1] + rng.randint(-200, 400))
    elif shape == "filling":
        # Steadily climbs past 0.90 — the compaction case.
        peak = int(n_ctx * rng.uniform(0.92, 1.05))
        step = max(1, (peak - base) // max(1, n_msgs - 1))
        for _ in range(n_msgs - 1):
            seq.append(seq[-1] + rng.randint(int(step * 0.6), int(step * 1.4)))
    elif shape == "burst":
        # Low-util prefix, then a jump (tool-heavy turn) into 0.70-0.95.
        jump_at = rng.randint(max(2, n_msgs // 3), n_msgs - 2)
        peak = int(n_ctx * rng.uniform(0.70, 0.95))
        for i in range(n_msgs - 1):
            if i + 1 == jump_at:
                seq.append(peak - rng.randint(0, 1500))
            else:
                seq.append(seq[-1] + rng.randint(150, 800))
    # Clamp to >0 and a small over-shoot ceiling (analyzer clamps to 1.0 anyway).
    return [max(1, min(int(round(t)), int(n_ctx * 1.10))) for t in seq]


def make_record(rng: random.Random, ts: datetime, prompt_tokens: int) -> dict:
    """Mirror the shape produced by proxy/src/server.js (jsonl.write call)."""
    completion = rng.randint(40, 600)
    rewrite_fired = rng.random() < 0.05  # rare: most requests passthrough
    rec = {
        "request_id": uuid.UUID(int=rng.getrandbits(128)).hex[:16],
        "model": "qwen3.8-local",
        "mode": "turboquant",
        "compact": "off",
        "stream": True,
        "message_count": rng.randint(2, 50),
        "prompt_tokens": prompt_tokens,
        "completion_tokens": completion,
        "status": 200,
        "latency_ms": rng.randint(200, 4500),
        "rewrite": (
            {
                "orig_tokens": prompt_tokens + rng.randint(500, 4000),
                "rewritten_tokens": prompt_tokens,
                "elided_ids": [],
            }
            if rewrite_fired
            else None
        ),
        "phantom_answered": 0,
        "session": None,
        "timestamp": ts.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    return rec


def synthesize(
    out_path: str,
    *,
    seed: int,
    days: int,
    sessions_per_day: int,
    n_ctx: int,
    start: datetime,
) -> tuple[int, int]:
    rng = random.Random(seed)
    sessions = 0
    records = 0
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        for d in range(days):
            day_start = start + timedelta(days=d, hours=9)  # ~9am local-ish
            cur = day_start
            for _ in range(sessions_per_day):
                shape = pick_shape(rng)
                toks = gen_session_tokens(rng, shape, n_ctx)
                t = cur
                for tk in toks:
                    rec = make_record(rng, t, tk)
                    f.write(json.dumps(rec) + "\n")
                    records += 1
                    t = t + timedelta(seconds=rng.uniform(*WITHIN_SESSION_GAP_S))
                sessions += 1
                gap_min = rng.uniform(*INTER_SESSION_GAP_MIN)
                # Ensure gap exceeds the analyzer session-gap so sessions split.
                gap_min = max(gap_min, SESSION_GAP_MIN + 5)
                cur = t + timedelta(minutes=gap_min)
    return sessions, records


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    ts_default = f"/tmp/synthetic-telemetry-{int(time.time())}.jsonl"
    p.add_argument("--out", default=ts_default, help=f"output JSONL path (default: {ts_default})")
    p.add_argument("--seed", type=int, default=20260507, help="PRNG seed (deterministic)")
    p.add_argument("--days", type=int, default=7)
    p.add_argument("--sessions-per-day", type=int, default=50)
    p.add_argument("--n-ctx", type=int, default=DEFAULT_N_CTX)
    p.add_argument(
        "--start",
        default="2026-04-29T00:00:00+00:00",
        help="ISO start timestamp for day 0 (default: 2026-04-29)",
    )
    args = p.parse_args(argv)

    if os.path.expanduser(args.out).startswith(
        os.path.expanduser("~/.cache/qwen-compact/logs")
    ):
        print(
            "refusing to write synthetic telemetry under the real telemetry dir "
            "(~/.cache/qwen-compact/logs/); choose another --out",
            file=sys.stderr,
        )
        return 2

    start = datetime.fromisoformat(args.start)
    if start.tzinfo is None:
        start = start.replace(tzinfo=timezone.utc)

    sessions, records = synthesize(
        args.out,
        seed=args.seed,
        days=args.days,
        sessions_per_day=args.sessions_per_day,
        n_ctx=args.n_ctx,
        start=start,
    )
    print(
        f"wrote {records} records across {sessions} sessions to {args.out}",
        file=sys.stderr,
    )
    print(args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
