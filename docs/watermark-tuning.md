# Watermark tuning

How to use `scripts/analyze-watermarks.py` to pick a compaction watermark from
real Phase 0 telemetry. Cross-references
[`compaction-strategy.md` §11](./compaction-strategy.md#11-open-questions) — the
"70% is a guess" open question this analyzer is designed to answer.

## What the analyzer does

Input: JSONL request logs the proxy writes to
`~/.cache/qwen-compact/logs/<UTC-date>.jsonl` (see `proxy/src/jsonl-logger.js`
and the `jsonl.write(record)` call in `proxy/src/server.js`).

Algorithm (`scripts/analyze-watermarks.py`):

1. **Parse + filter.** Each line is decoded; records without a usable
   `prompt_tokens` (or `rewrite.orig_tokens` / `rewritten_tokens` fallback) and
   a parseable ISO `timestamp` are dropped.
2. **Session reconstruction.** The proxy does not persist a session id, so the
   analyzer sorts all records by timestamp and splits on inactivity gaps
   (`--session-gap-min`, default 15 minutes). Each session is a list of
   `(ts, prompt_tokens)` points.
3. **Utilization curve.** For each session, compute `ratio = tokens / n_ctx`
   per request (clamped to 1.0). The peak ratio defines whether the session
   "filled" the window — the threshold is 90% (`FILL_THRESHOLD`).
4. **Replay candidates.** For each watermark in `{50, 60, 70, 75, 80}%`, find
   the index of the *first* request that crossed it.
5. **Report per watermark:**
   - `sessions_triggered` / `trigger_rate` — how many sessions the watermark
     would have fired on (and the share of all sessions).
   - `avg_lead_messages` — mean count of messages between the trigger and the
     session's peak. Larger is better: it's the budget the summarizer has to
     run before the user actually needs the freed tokens.
   - `false_positives` / `FPR` — sessions where the watermark fired but the
     session never reached 90% utilization. These are unnecessary compactions.
6. **Suggest.** The script picks the watermark with the lowest FPR, breaking
   ties on largest average lead.

## How to read the columns

- **Trigger rate.** A trigger rate near 100% means you are compacting almost
  every session — too aggressive. Near 0% means the watermark is dead code.
  Aim for the trigger rate to roughly match the share of sessions that
  actually fill the window (the `Sessions filled` header line).
- **Avg lead.** Below ~3 messages is too late; the summarizer is a 4B model
  and a streamed reply costs seconds. Above ~10 typically means you tripped on
  a wide plateau and most of those messages weren't going to grow anyway.
- **FPR.** This is the most expensive number to be wrong on: every false
  positive is a model invocation and a quality dilution for no benefit.

## Choosing a watermark

Prefer the lowest FPR among watermarks whose `avg_lead` is at least the
[Tier-3 summarizer wall-clock budget](./compaction-strategy.md#tier-3--prose-summarization-small-model-async)
in messages (rule of thumb: 3-5 messages on M-series). The script's automatic
suggestion encodes that rule; treat it as a starting point, not an oracle.

## Real telemetry vs. synthetic

`scripts/synthesize-telemetry.py` fabricates a week of plausibly-shaped
sessions (mix of short / medium / filling / burst) for testing the analyzer
itself. **Do not tune watermarks against synthetic data** — the shape mix is
hand-picked, not measured. Once the proxy has run in shadow mode (`compact:off`
records still log) for a full week:

1. `make analyze-watermarks` reads from the real path by default.
2. Real data should show a heavier tail than the synthetic mix (long
   debugging sessions skew filling), and the FPR floor will be model- and
   workload-specific.
3. Re-run weekly until two consecutive runs agree on the same watermark; that
   is the value to commit to `compaction-strategy.md` §5.

## End-to-end smoke test

```sh
python3 scripts/synthesize-telemetry.py --out /tmp/syn.jsonl
make analyze-watermarks ARGS="--logs /tmp/syn.jsonl"
make analyze-watermarks ARGS="--logs /tmp/syn.jsonl --csv"
```

Synthetic output **must not** be written under `~/.cache/qwen-compact/logs/`;
the synthesizer refuses that path so real telemetry stays clean.
