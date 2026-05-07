# A/B Harness — Proxy Compaction Variants

Compares the proxy's compaction strategies on identical fixture sessions.
The harness invokes a small Node CLI shim (`proxy/scripts/run-rewrite.js`)
that runs `proxy/src/rewrite.js` in-process against each fixture, then
folds the per-cell rows into the §11 metric shape from
`docs/hooks-middleware.md`.

The harness is **offline**: a deterministic chars/4 stub tokenizer is used,
no proxy server is started, and no upstream model is contacted. Live-proxy
end-to-end measurement (with `x-rewrite-stats` and a real tokenizer) is
tracked separately — see `docs/hooks-middleware.md §11` and the comment in
the shim.

## Layout

```
ab-harness/
  README.md       — this file
  runner.py       — argparse entrypoint; iterates variants × fixtures × seeds
  variants.py     — declarative variant matrix (proxy_config + headers)
  aggregate.py    — folds per-cell rows into the §11 metric shape + md table
  fixtures/       — 5 synthetic session JSONLs (≤200 KB combined)
    _generate.py    — regenerator (deterministic, no RNG)
    tool-heavy.jsonl
    chit-chat.jsonl
    decision-heavy.jsonl
    code-review.jsonl
    mixed-prose-tool.jsonl
  __init__.py
```

The Node shim lives at `proxy/scripts/run-rewrite.js` (sibling tree).

## How to run

```bash
# Single fixture, two variants:
python3 runner.py \
    --fixture fixtures/tool-heavy.jsonl \
    --variants do-nothing,tier0+tier1 \
    --seeds 1 \
    --output ./out

# Full smoke (5 fixtures × all 6 variants):
python3 runner.py --all --seeds 1 --output ./out

# Aggregate the result tree into a markdown table for §11:
python3 aggregate.py --input ./out --baseline tier0+tier1 \
    --md-out ./out/table.md --json-out ./out/aggregate.json
```

Output: one `<variant-id>.json` file per variant under `--output`. Each row
matches `runner.METRIC_KEYS`:

```
{variant, seed, fixture, prompt_tokens, rewritten_tokens, completion_tokens,
 latency_ms, needle_recovery, decision_preservation, turns_completed, error}
```

Needle and decision-marker grading are string-exact: each fixture embeds a
`NEEDLE[<id>]: <fact>` span and (where applicable) `AGREED [D-NN]` /
`[CR-NN]` / `[MX-NN]` markers. `runner.py` reads the rewritten message text
via the shim and asserts the literal substring survives. The expected
needle text per fixture is in `runner.NEEDLE_FACTS`.

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

## Fixtures

All five fixtures are deterministic and synthetic — no real user data. To
regenerate after editing `_generate.py`:

```bash
python3 fixtures/_generate.py
```

Each fixture embeds exactly one `NEEDLE[<id>]: <fact>` span; `runner.py`
asserts the literal fact substring survives compaction. `decision-heavy`,
`code-review`, and `mixed-prose-tool` additionally carry `AGREED` markers
graded by `decision_preservation`. Combined size is capped at ~200 KB.

## Node shim — `proxy/scripts/run-rewrite.js`

The Python runner shells out to this Node script per cell:

```bash
node proxy/scripts/run-rewrite.js \
    --fixture proxy/eval/ab-harness/fixtures/tool-heavy.jsonl \
    --variant tier0+tier1
```

It reads the fixture, builds an OpenAI-style request body, calls
`rewriteRequest()` from `proxy/src/rewrite.js` with a deterministic chars/4
stub tokenizer, and prints one JSON line on stdout shaped for the harness.
No new Node dependencies (uses `node:fs`, `node:path`, `node:url`, and
`node:perf_hooks` only).

The shim's variant table mirrors `variants.py`:
- `do-nothing`, `caveman-self-compact` → passthrough (no `rewriteRequest`).
- `tier0-only`, `tier1-only` → run `rewriteRequest` with one of the two
  watermark axes neutralised. **Note:** today's `rewrite.js` does not
  expose Tier 0 / Tier 1 as independent toggles (Tier 0 selects the
  candidates that Tier 1 stubs), so these two variants currently report
  no-op results. This is documented in §11 of `docs/hooks-middleware.md`
  and is the expected behavior until the hook engine lands.
- `tier0+tier1` → production-shape leg.
- `tier1+hooks` → falls back to `tier1-only` numbers until the hook
  engine (#39, sibling task) lands. The harness flags this in its output.

## Next steps

- **#39 (sibling)**: hook engine in `proxy/src/hooks/` — once it lands,
  remove the `tier1+hooks` fallback in `proxy/scripts/run-rewrite.js` and
  drop the `*` footnote in §11.
- Live-proxy mode: re-run with the proxy actually started and assert the
  shim numbers match `x-rewrite-stats` end-to-end. See the §11 separate
  ticket on `x-rewrite-stats` emission in enforce mode.
