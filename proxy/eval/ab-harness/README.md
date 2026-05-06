# A/B Harness — Proxy Compaction Variants

Scaffold for comparing the proxy's compaction strategies on identical fixture
sessions. The harness drives `proxy/eval/replay.py` against a proxy configured
per-variant and aggregates per-cell metrics into per-variant JSON files.

**Non-goals:** This is a scaffold; real measurement and report generation land
in subsequent tasks (#23, #24, #25, #26).

## Layout

```
ab-harness/
  README.md       — this file
  runner.py       — argparse entrypoint; iterates variants x seeds
  variants.py     — declarative variant matrix (proxy_config + headers)
  fixtures/       — session JSONLs land here in a later task
  __init__.py
```

## How to run

```bash
python3 runner.py \
    --fixture fixtures/needle_50turns.jsonl \
    --variants do-nothing,tier0+tier1 \
    --seeds 3 \
    --output ./out
```

Output: one `<variant-id>.json` file per variant under `--output`, each
containing a list of stub metrics rows (one per seed). Today every value is
zero — the runner exists to exercise the matrix plumbing while the live-proxy
wiring is being designed in parallel.

The metrics dict shape is fixed (see `runner.METRIC_KEYS`):

```
{variant, seed, fixture, prompt_tokens, completion_tokens, latency_ms,
 needle_recovery, decision_preservation, turns_completed}
```

## Variants

Defined in `variants.py`. Add a new entry to `VARIANTS` and document it here.

| id                     | what it does                                                        |
| ---------------------- | ------------------------------------------------------------------- |
| `do-nothing`           | Passthrough proxy with `x-compact: off`. Control leg.               |
| `caveman-self-compact` | No proxy rewrite; the model summarizes itself when marked.          |
| `tier0-only`           | Tier-0 cheap-heuristic stubbing only.                               |
| `tier1-only`           | Tier-1 LLM summarizer only.                                         |
| `tier0+tier1`          | Both tiers — production-shape leg.                                  |
| `tier1+hooks`          | Tier-1 plus the new middleware/hook system (parallel design task).  |

The `tier1+hooks` variant must NOT assume the hook code exists yet; the runner
gates it behind a feature flag at execution time.

## Where results go

Per-invocation: whatever path is passed to `--output`. By convention, use a
timestamped directory under `proxy/eval/ab-harness/out/` (gitignored) when
running locally; CI will pick its own location.

The cross-variant report (markdown + CSV) is produced by a separate tool that
will land in #26 and will read every `<variant-id>.json` from the output dir.

## Conventions

- Stdlib only (matches `proxy/eval/replay.py` and `proxy/eval/needle.py`).
- No pytest dependency; integration is exercised via `proxy/eval/run_smoke.sh`.
- Offline-mode safe: the scaffold makes no network calls.
- Variant ids must be filesystem-safe — they become JSON filenames.

## Next steps

- **#23**: Wire `runner.run_one()` to launch the proxy with the variant's
  `proxy_config` overrides and drive it via `proxy/eval/replay.py`.
- **#24**: Pull `needle_recovery` from `proxy/eval/needle.py verify` after
  issuing the recall turn against the live proxy.
- **#25**: Compute `decision_preservation` by diffing tool-call sequences.
- **#26**: Emit a cross-variant report (markdown + CSV) under `--output`.
