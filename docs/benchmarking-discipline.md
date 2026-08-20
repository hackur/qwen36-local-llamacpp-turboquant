# Benchmarking discipline

Observations from a 2026-05-25 session that wired up `qwen36-mtp` and ran an
ad-hoc comparison against turboquant through the hermes agent. Captured here
so the same mistakes don't repeat.

## What went wrong

### Wall-time through hermes is not a model speed measurement

A "comparison" was presented as:

| | MTP | Turboquant |
|---|---|---|
| Wall time | 2m 19s | 2m 40s |
| Answer length | ~63 words | ~28 words |

Both numbers were dominated by hermes agent init (tool discovery, system
prompt) — generation was a small fraction of each. Output lengths differed
by 2×. The table invites a speed inference that the data does not support.

### Quant/fine-tune mismatch invalidates quality claims

The two endpoints were running different artifacts:

- MTP: Qwen3.6-27B base, UD-Q4_K_XL
- Turboquant: Qwen3.6-27B **NEO-CODE** fine-tune, Q5_K_M

Any quality delta between single answers cannot be attributed to MTP vs
turboquant — it could equally be the fine-tune, the quant, or sampling
noise. One prompt is not a sample.

### Numbers without controls

Every reported figure (gen tok/s, draft-accept %, wall time) was a single
observation with no fixed `max_tokens`, no warm-state control, no repeat
runs, and no confidence bound.

## Rules going forward

1. **Never compare wall time through an agent harness.** Bench at the
   llama-server `/v1/chat/completions` layer with a fixed prompt and fixed
   `max_tokens`. Agent-layer timing is for agent-layer questions only.
2. **Match the artifact.** A vs B comparisons require the same model
   weights and the same quant unless the variable under test *is* the
   quant or fine-tune. Otherwise call it a "smoke test", not a comparison.
3. **Warm both sides first.** Discard the first response (prompt-eval cost,
   KV cold). Report a median over ≥3 runs at minimum.
4. **Quote `max_tokens` and `n_predict` in every result.** Tokens-per-second
   without a length floor is meaningless when one answer is 28 words and
   the other is 63.
5. **One server at a time on the M3 Max.** See
   [memory: thermal caution]. Two llama-servers concurrently for one A/B
   round-trip is the ceiling; never stack benches.
6. **Smoke test ≠ verification.** A single successful round-trip proves
   the wiring is connected, not that it works correctly under load or
   produces correct outputs in general.

## Tooling

Two harnesses, same discipline:

- **`scripts/bench-ab.sh`** — zero-dep bash, two ports + labels, N=5 warm,
  median/min/max. Refuses to run if both ports listen at once. Good for
  one-off A/B passes.
- **`scripts/bench_runner.py`** + **`scripts/bench_tui.py`** — Python
  suite runner with append-only `events.jsonl` / `control.jsonl`
  protocol and a Textual TUI. Suites live in `benchmarks/suites/*.yaml`.
  Same thermal rule (lockfile + port-solo polling). Install:
  `pip install -r requirements-tui.txt`. Run: `make bench-suite SUITE=…`
  (headless) or `make bench-tui SUITE=…` (interactive).

The TUI never starts/stops llama-servers itself — that's deliberate.
You control thermal pacing by bringing each side up between job phases.

## Runner protocol (source of truth)

This section is the integration contract between `scripts/bench_runner.py`
(producer) and `scripts/bench_tui.py` (consumer). Both files are
append-only JSONL, UTF-8, one event per line, ISO-8601 UTC timestamps.
Agents must not negotiate the schema — change it here first, then code.

### Run directory layout

Each invocation creates a fresh run directory under `benchmarks/runs/`:

```
benchmarks/runs/<run-id>/
  events.jsonl     # runner writes, TUI reads (tail -f style)
  control.jsonl    # TUI writes, runner reads between runs
  summary.json     # runner writes once at end
  <job-id>.json    # per-job raw timing records
```

`<run-id>` is `YYYYMMDD-HHMMSS`.

### events.jsonl (runner -> TUI)

One status event per line. Per-run sample and per-job completion events:

```json
{"ts":"2026-05-25T18:00:00Z","job":"turboquant-vs-mtp","phase":"running","side":"A","run":3,"tok_s":61.4}
{"ts":"2026-05-25T18:01:30Z","job":"turboquant-vs-mtp","phase":"ok","summary":{"a":{"median":61.5,"min":60.2,"max":62.1},"b":{"median":15.4,"min":14.9,"max":16.0}}}
```

`phase` is a closed set: `queued`, `waiting_port`, `warming`, `running`,
`ok`, `failed`, `skipped`, `stopped`. No other values are valid.

### control.jsonl (TUI -> runner)

The runner reads new lines between every run iteration:

```json
{"action":"stop","job":"<id>"}
{"action":"skip","job":"<id>"}
{"action":"start","job":"<id>"}
```

`stop` aborts the named job and marks it `stopped`; `skip` marks a queued
job `skipped` without running; `start` promotes a queued job to the front
of the queue. The TUI never mutates `events.jsonl` — runner is the single
source of truth.

### One bench at a time

The runner holds an exclusive lockfile at `benchmarks/runs/.bench.lock`
and refuses to start while another runner holds it. Within a job, if both
A and B ports listen simultaneously, the runner reports `waiting_port` and
polls — it will never time both sides concurrently. This preserves the
thermal rule on M3 Max.

### TUI keybinds

Navigation and control glyphs are documented in `scripts/bench_tui.py`
(run with `--help` or read the top-of-file docstring).

## Pattern to watch

The instinct is to *do* (refactor, wire, ship) and then report a number
because a number feels like proof. For an inference-tuning repo, measuring
is the core skill. Slow down at the numbers, not at the plumbing.
