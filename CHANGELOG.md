# Changelog

## Unreleased

### Added

- **Single-server guard (`single-server guard:v1`)** in `scripts/_common.sh` — every `start-*.sh` now refuses to launch if any other `llama-server` is already running, even on a different port. Stacking servers on this M3 Max risks sustained thermal load and skews benchmark numbers; the guard surfaces the surviving pid(s) and points to `stop-all.sh`. Override with `ALLOW_STACK=1` for intentional A/B on a cool chassis. Wired into `start-baseline`, `start-fallback`, `start-embed`, `start-vision`, `start-turboquant`, `start-qwen36-mtp` (the last two only in non-`--dry-run` paths).

### Fixed

- **`scripts/stop-all.sh` race + survivor reporting.** Previous single-pass SIGTERM-then-SIGKILL design missed pids spawned between passes (live repro: pid 68346 received SIGKILL but was never in the SIGTERM list; pid 68938 survived entirely despite "✓ stopped" being printed). Now: bounded retry loop (max 5 passes), per-pid `kill -0` check before SIGKILL, final re-scan that exits non-zero with surviving pids printed to stderr. `✓ stopped` now means the machine is actually clean.

### Docs

- `docs/troubleshooting.md` — new entry for the `Another llama-server is already running` error, `ALLOW_STACK=1` override, and the strengthened `stop-all.sh` semantics.

## v0.0.2 — 2026-05-07

Second release. Headlines: default model swapped to `qwen36-neo`, the compaction proxy grew through Phases 2–5 plus a Phase 6 hook engine, the hooks-middleware spec was ratified and wired into the A/B harness for real §11 battle-test numbers, six sustained-load runbook scripts landed (one already used to reproduce thermal-throttle live), and a telemetry pipeline was built end-to-end (analyzer + synthesizer + tuning guide). KV-cache math was corrected by 4×, a launchd-killing bash 3.2 bug was fixed, an upstream-timeout hole in the proxy was closed, the bench-summarizer's orphan-server bug was fixed, and operational guard-rails (mixed K/V, opt-in metrics, quarterly LM Studio re-audit, --help that doesn't launch servers, privacy-scan that doesn't trip on its own docs) were added. Verified live on hardware: 5/5 quality-check, vision e2e, audit-offline clean, thermal-throttle reproduced, 100K-needle long-context recall pass, summarizer bench across 3 candidates → nemotron-4b recommended.

### Changed

- **Default model swapped** from `qwen36-35b` (Qwen3.6-35B-A3B Q6_K MoE) to `qwen36-neo` (Qwen3.6-27B Heretic-Uncensored NEO-CODE Q5_K_M dense, ~19.5 GB). Native 256K context (`n_ctx_train`), uncensored, code-tuned. `qwen36-35b` is preserved as `MODEL_FALLBACK` in `scripts/_common.sh`.
- `scripts/demo-chat.sh` rewritten as `scripts/demo-chat.py` (stdlib-only Python module). The shell file is now a one-line shim. Fixes three real bugs: invisible thinking output, C0-control corruption of streamed markdown, and phantom replies on bare-Enter input.
- `scripts/static-check.sh` now also runs `python3 -m unittest discover -s tests`.
- **Per-model defaults system.** `scripts/start-turboquant.sh` now resolves CTX/RoPE/etc. via `load_model_defaults` (in `scripts/_common.sh`) sourcing `configs/model-defaults.env`. Precedence: explicit env > per-model default > generic default > script-default.
- **Default CTX for `qwen36-35b` raised 131072 → 262144** (its `n_ctx_train` cap). Measured turbo3 KV at 256K is 1344 MiB — much lower than the 11.6 KiB/tok @64K extrapolation predicted, since turbo3's fixed overhead amortizes at large context.
- **KV-cache math corrected.** `docs/kv-cache-math.md`, `docs/architecture.md`, and `docs/context-matrix.md` previously claimed Qwen3.6-35B-A3B was 64 layers / 8 KV heads / head_dim 128 (~80 KB f16/tok). Actual GGUF metadata: 40 blocks / 2 KV heads / head_dim 256, with `full_attention_interval=4` → only 10 layers carry KV → ~20 KiB f16/tok. The 4× error meant the doc-reported "max 32K @ f16" was actually closer to 256K. All three docs corrected.
- **Stale 35B-A3B baselines** in `docs/architecture.md` and `docs/context-matrix.md` updated to lead with `qwen36-neo`, with the 35B-A3B preserved as fallback context.
- `--metrics` is now **opt-in** — `METRICS=1` env in `scripts/start-turboquant.sh`, default off so `/metrics` does not leak generation counts to anything with localhost access. Sentinel `metrics-opt-in:v1`.
- `configs/opencode.json` display name dropped the stale `35B-A3B` label.
- `docs/system-info.md` date refreshed 2026-04-27 → 2026-05-06.
- `docs/troubleshooting.md` gained sections for proxy port `:11500`, run-to-run variance, mixed-K/V slowdown, port-guard, and privacy-gate failures.
- `docs/install-models.md` cosmetic skip-message wording fix.

### Added

- `start-qwen36-neo` Makefile target.
- **Compaction reverse proxy** at `proxy/` (Node/Fastify, `:11500` → `:10501`) with passthrough/shadow/enforce modes, Tier-1 elision (tool-result truncation + `expand_tool_result` phantom tool), and per-request JSONL logging. Operator quickstart in `docs/proxy.md`.
- Make targets: `proxy-install`, `proxy-test`, `proxy-start`, `proxy-smoke`.
- `summarizeElidedIds()` helper in `proxy/src/tier1.js` to bound `x-rewrite-stats` response-header size.
- Replay + needle eval harness under `proxy/eval/` (50-turn fixture, regex grader, mock-proxy tests).
- Proxy unit + stub-upstream integration tests under `proxy/tests/`.
- **Proxy Phase 2** recursive summarizer hook (`proxy/src/summarizer.js`, `rewrite.js` Phase 2 hook gated on `summarizer.url` + `mode: shadow|enforce`). Inline replacement; `expand_tool_result` covers rehydration. 8 new tests.
- **Proxy Phase 3** session keying (`proxy/src/session.js`: `keyForRequest`, `extractStablePrefix`, TTL session map, slot save/restore stubs). New `session:` config block. 5 new tests.
- **Proxy Phase 4/5** structured notes + sumy fallback (`proxy/src/notes.js` + Tier-2/3/4 hook in `rewrite.js`). New `notes:` and `sumy:` config sections. Layering: Phase 2 → Phase 4 → Phase 5 → Tier 1. 6 new tests.
- **Hooks-middleware v0.2 spec** with all 16 amendments from the v0.1 review applied (per-phase scratch fields, tags read-only, mutation visibility, `replace('messages')` writeback, mutate collisions, `HookPhaseClosedError`, inject fallbacks, handler signature, `predicate_module`, §6.5 Handler Resolution, `stream:context-trigger` semantics, §12 byte-identity caveat, §11 variant naming, metric aggregation, `x-rewrite-stats` note, naming convention).
- **Hook engine + 5 built-in handlers** at `proxy/src/hooks/{engine, registry, tag-bash-read-elisions, context-pressure-reminder, prose-summarize, once-per-session, session-hint-loader}.js`. Wired into `server.js` at four request phases with a `NULL_HOOKS` sentinel + `hasHooksFor` early-out so configs without `hooks:` pay zero per-request cost. New `hooks: {enabled, default_timeout_ms, handlers[]}` config. 15 new tests. **MVP scope deviations:** `stream:*` and `response:*` phases registered but do not fire; `HookPhaseClosedError` not enforced at runtime; partial filter DSL.
- **A/B harness fixtures + populated §11 battle-test table.** 5 fixtures (~180 KB) under `proxy/eval/ab-harness/`, `runner.py` extended with subprocess shim, `aggregate.py` for the §11 metric shape, `proxy/scripts/run-rewrite.js` Node CLI shim. Smoke run: 30 cells, 2.1 s, 0 errors, 100% needle + decision preservation; tier0+tier1 −49.9% on tool-heavy fixtures.
- **Embeddings server scaffold** — `scripts/start-embed.sh` (sentinel `embed-server:v1`, port 10510, KV f16, `--embedding`), Makefile target, `docs/api.md` updated.
- **Summarizer benchmarking** — `scripts/bench-summarizer.sh` runs gemma4-e4b vs nemotron-4b vs tiny on 5 inline fixtures using transient ports 10520-22, captures load/prefill/gen tps + summary text, writes `benchmarks/summarizer-bench-<ts>.md`.
- **Watermark analyzer** — `scripts/analyze-watermarks.py` (stdlib) reads `~/.cache/qwen-compact/logs/*.jsonl` and reports trigger rate, FPR, and lead time per candidate watermark, suggests minimising FPR with lead-time as tiebreak. `--csv` flag, Makefile target.
- **Variance diagnostic** — `scripts/diagnose-variance.sh` snapshotter for the neo gen tok/s variance investigation. Surviving hypothesis: GPU residency-set / KV eviction churn at 128K (256K saturates so eviction cannot happen — explains the asymmetry).
- **Quarterly LM Studio re-validation** — `scripts/quarterly-audit.sh`, `configs/launchd-quarterly.template` (Jan/Apr/Jul/Oct 09:00 local), Makefile target, subsection in `docs/offline-mode.md`.
- **Mixed K/V guard rail** — `apply_kv_split` helper in `scripts/_common.sh`, `KV_K`/`KV_V` env contract, `MIXED_KV_OK=1` silencer, sentinel `mixed-kv-guard:v1`. Wired into `start-turboquant.sh` and `start-vision.sh`.
- **Upstream tracking doc** — `docs/upstream-tracking.md` pins TurboQuant `11a241d` (2026-04-24) and mainline `683c5acb9` (2026-04-29), records q8_0 pins for tiny + gpt-oss-20b, gives a quarterly recheck recipe. Cross-referenced from `configs/model-defaults.env`.
- `tests/test_demo_chat.py` (33 stdlib-only cases for the REPL).
- `docs/demo-chat.md` user reference for the rewritten REPL.
- Round-4 / Round-5 / Round-6 / Round-7 sections in `HANDOFF.md`.
- `qwen36-neo` rows in `benchmarks/SWEEP.md` and `docs/kv-cache-math.md` with measured KV-cache footprints (15.2 KiB/tok at turbo3, ~22.7 GB total VRAM @ 256K).
- `configs/model-defaults.env` — per-model default knobs (CTX, RoPE flags, etc.).
- `scripts/_common.sh::load_model_defaults` and `scripts/_common.sh::rope_args` helpers, wired into `scripts/start-turboquant.sh`.
- **RoPE/YaRN escape-hatch** for one-shot context extension past `n_ctx_train`. Env vars `ROPE_SCALING`, `ROPE_SCALE`, `YARN_ORIG_CTX` plumbed through `start-turboquant.sh` as `--rope-scaling --rope-scale --yarn-orig-ctx`. Workflow (transient YaRN-2× server → compact-to-JSON → reload in fresh un-scaled session) documented.
- **Compact-and-save workflow** verified end-to-end (7-message synthetic conversation → 1.4 KB JSON → fresh session recovers all facts). New `snapshots/` directory convention (gitignored).
- **Vision memory pre-flight** in `scripts/start-vision.sh`: estimates total need (model GGUF + mmproj + 1.5 GiB KV scratch + summed RSS of other running `llama-server` PIDs + 4 GiB headroom) vs `hw.memsize`; aborts unless `FORCE=1`. Sentinel `memory-preflight:v1`.
- **Privacy pre-push hook (opt-in).** `scripts/privacy-scan.sh` extracted from `static-check.sh`; `scripts/git-hooks/pre-push` available as a manual symlink (not auto-installed). `Makefile` targets `privacy-scan` and `prepush`. `CONTRIBUTING.md` updated with the symlink one-liner.
- `port-guard:v1` sentinel in `_common.sh`'s `ensure_port_free`.
- `proxy/eval/ab-harness/` scaffold (now populated with fixtures + runner — see §11 battle-test entry above).
- `docs/m5-readiness.md` confirms pre-M5 LUT path via existing dogfood logs and tags tensor-API items as wait-for-M5.
- **`qwen3.5-0.8b` model alias** — the tiniest Qwen 3.5/3.6-family GGUF on HuggingFace (`unsloth/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q8_0.gguf`, ~775 MB). Standalone use plus the speculative-decoding draft for the larger Qwen3.5/3.6 targets (shared tokenizer family). Wired into `scripts/symlink-models.sh` and `configs/model-defaults.env` (CTX 32768 / KV turbo3).
- **Sustained-load runbook scripts** — `scripts/{sweep-ctx-batch,ablate-sparse-v,test-np-concurrency,test-spec-decode}.sh`. One-shot runners that share the same shape: refuse to collide with the launchd primary on `:10501`, ensure_port_free, apply_kv_split, load_model_defaults, /health-wait, run, capture, tear down, append to `benchmarks/<bench>-<ts>.md` so partial runs survive a kill, all wrapped with `diagnose-variance.sh` pre/post snapshots.
- `docs/speculative-decoding.md` — concept, draft acquisition, when-it-helps, tunables, tokenizer-mismatch pitfall, `/props` vocab check; cross-linked from `docs/usage.md`.
- `docs/troubleshooting.md` "Sustained-load runs" subsection — one paragraph per runbook with expected runtime and a "stop if you see X" warning.
- `scripts/test-battery-ac.sh` (#46) — sixth sustained-load runbook, same shape as the others. Troubleshooting paragraph added.
- `scripts/compare-lmstudio.sh` (#13) — TurboQuant vs LM Studio comparison runbook. Probes `:1234` + `:10501` via `/v1/models`, refuses port collisions, loose Qwen-vs-Qwen check (warns on mismatch), 60 s cooldown between arms, output `benchmarks/lmstudio-compare-<ts>.md` with mean ± stddev for both runtimes plus a one-line conclusion. Read-only against the live primary; not yet executed (waits for the user to start LM Studio).
- `scripts/synthesize-telemetry.py` — stdlib telemetry synthesizer for the watermark analyzer. Deterministic seed, refuses to write under `~/.cache/qwen-compact/logs/`, generates ~1500 records across 4 session shape types (short/medium/filling/burst). `--out`, `--seed`, `--sessions-per-day` flags.
- `docs/watermark-tuning.md` — interpretation guide for `analyze-watermarks.py` output: 6-step algorithm, how to read each column, FPR-then-lead selection rule, synthetic vs real telemetry expectations, weekly re-run workflow until two consecutive analyses agree before committing the value to compaction-strategy §5. Cross-linked from §11.
- `print_help_from_header` helper in `scripts/_common.sh` (and inline awk equivalent for the three scripts that don't source `_common.sh`).
- `preflight_memory` lifted from `start-vision.sh` into `scripts/_common.sh` so text-only callers can reuse it. `start-vision.sh` and `start-embed.sh` now also call `load_model_defaults` so per-alias CTX/KV/RoPE actually applies; `start-embed.sh` now honours `KV_K`/`KV_V`.
- `proxy/src/config.js`: `watermarks.verbatim_keep_turns` and `verbatim_keep_tokens` added to `DEFAULTS` so a partial user override no longer silently drops them via `deepMerge` (behavior unchanged — `rewrite.js` already had `?? 8` / `?? 8000` fallbacks; this prevents future drift).
- A/B harness `tier1+hooks` row now wired through the real hook engine in `proxy/scripts/run-rewrite.js` (pre-counts prompt tokens, builds synthetic `ctx` with `nCtx=32768`, registers `context-pressure-reminder` at `request:before-rewrite` + `tag-bash-read-elisions` at `request:after-rewrite`, mirrors `server.js`). Surfaces `hook_tags`, `hook_timings_ms`, `hook_errors`, `total_hook_time_ms`. `runner.py` `METRIC_KEYS` extended; `aggregate.py` distinguishes shim-error rate from hook-error rate. §11 placeholder rows replaced with real numbers; footnote rewritten to describe the actual wiring.
- `proxy/config.yaml`: 5-line summarizer-block comment recording the bench result and pointing at `benchmarks/summarizer-bench-20260507-215050.md`. Default `model:` field unchanged — flip to `nemotron-4b` once Phase 2 is wired end-to-end.
- README "What's new in v0.0.2" section + capability/layout/further-reading rows for the new artifacts (proxy phases, hooks engine, runbook scripts, qwen3.5-0.8b draft alias, embeddings server, upstream-tracking, quarterly re-audit, mixed-K/V guard, opt-in `/metrics`, KV-math correction).
- `proxy/README.md` rewritten as a 54-line stub (was stuck at "Phase 0" while the running proxy ships through Phase 6); points at `docs/proxy.md` for canonical config-knob coverage.

### Fixed

- `proxy/python/compact.py`: short prose under the token budget no longer collapses to a single sentence — fast-path passes through verbatim. Regression covered by a new test.
- `proxy/src/server.js` `sniffUsage()`: previously a flat regex (`\{[^}]*\}`) that bailed at the first inner `}`, so `completion_tokens` was always logged as `null` for real llama-server responses (which nest `prompt_tokens_details` inside `usage`). Replaced with a brace-balancing parser that handles nested objects, escaped quotes, and braces inside string content. Regression covered by `proxy/tests/sniff-usage.test.js` (7 cases).
- `scripts/start-turboquant.sh`: `${ROPE_FLAGS[@]}` under `set -u` blew up on macOS bash 3.2 when the array was empty (the no-RoPE common case), causing the launchd-managed primary to spin-restart. Both occurrences now use `${ROPE_FLAGS[@]+"${ROPE_FLAGS[@]}"}`. A second sibling site on the spin-restart path was patched in this release.
- `scripts/diagnose-variance.sh` would occasionally hang on `pmset -g thermlog`; now wrapped in a 2 s `timeout`.
- **Proxy upstream timeout actually applied.** `proxy/src/config.js` loaded `upstream.request_timeout_ms` into `DEFAULTS`, but `server.js`'s `fetch()` to `:10501` had no timeout — a hung upstream stalled the proxy forever. Now wrapped in `AbortController` + `setTimeout`; pre-stream timeout returns `504 {error:{type:"upstream_timeout", ...}}`; mid-stream timeout emits a clean `data: [DONE]\n\n` terminator before aborting so OpenAI-style clients exit their read loop. 3 new tests (`proxy/tests/upstream-timeout.test.js`); suite 126 → 129.
- **`--help` no longer launches `llama-server`.** Pre-tag audit found that running any of the runbook/diagnostic scripts with `--help` silently fell through arg parsing and triggered a real server launch (one audit invocation actually started two transient servers on `:10520-10521`). Early `case "${1:-}" in -h|--help)` guard added to all 9 runbook + diagnostic scripts (`sweep-ctx-batch`, `ablate-sparse-v`, `test-np-concurrency`, `test-spec-decode`, `test-battery-ac`, `bench-summarizer`, `diagnose-variance`, `quarterly-audit`, `privacy-scan`). `start-turboquant.sh` `--dry-run` now skips `ensure_port_free` (preview shouldn't be blocked by a busy port).
- **`scripts/bench-summarizer.sh` leaked `llama-server` processes.** `start_model` launched `start-turboquant.sh` in the background and tracked `$!`, but the wrapper internally `exec`s into `llama-server | tee`, reparenting the real server PID. Killing the wrapper PID hit only the wrapper; the actual server kept running. Manifested today: a #42 bench run left three transient servers on `:10520-10522`, pushed the system to 0.1 GiB free / 95 % swap, and caused the #10 100 K-needle test to time out at 600 s prefill. Fix: after `wait_health` succeeds, look up the actual `llama-server` PID via `lsof -nP -iTCP:$port -sTCP:LISTEN -t` and kill that. Belt-and-suspenders kill of any port-bound process on the failed-start path.
- **Audit fallout (post-tag).** `docs/proxy.md` test count drift "126 tests" → "129 tests" (the upstream-timeout fix added 3; the audit batch only refreshed to 126). `scripts/privacy-scan.sh` was tripping on its own teaching examples in `docs/troubleshooting.md` (the doc literally documents the `/Users/you` and `/path/to/project` patterns the scan looks for); added `':!docs/troubleshooting.md'` to the git-grep exclude list so the pre-push hook stops refusing pushes.

### Verified live (proxy round-trip against llama-server :10501)

- Basic chat (non-streaming + SSE).
- Tool calling: function definitions forward, `tool_calls` come back, `tool_choice:"auto"` honoured. Streaming tool-call deltas pass through with `[DONE]` terminator.
- Tool-result round-trip: assistant `tool_calls` + `role:"tool"` reply + follow-up assistant message all produce a grounded answer.
- Tier-1 elision under live conditions: 44 K-token request with a 36 KB tool result outside the verbatim window compacted to 36 K tokens (`elided_tool_result_ids:["call_BIG"]`), original persisted to `~/.cache/qwen-compact/tool-results/<id>.json`, stub message carries `<tool_result id=... bytes=N first_lines=...>` preview.
- `expand_tool_result` phantom-tool interception: assistant call to `expand_tool_result(id=...)` is answered locally from the cache before the upstream sees it; `phantom_answered:["call_X1"]` recorded in the JSONL row.
- `proxy/tests/integration.sh` extended with two new checks (non-streaming tool call, tool-result round-trip, plus an `x-debug-rewritten` contract check). Suite: 9/9 pass against live `:10501` + `:11500`.
- Regression coverage added: `sniffUsage` cases, tool-calling paths, `expand_tool_result` compaction validation (6 new tests).

### Verified live (on hardware)

- **Thermal-throttle reproduction** — three back-to-back A/B runs on the turboquant primary collapsed gen tok/s **13.92 → 7.69 → 4.11** (−45 % run 2, −70 % run 3). Recorded in `benchmarks/RESULTS.md` (2026-05-07 entry). A/B vs baseline f16 deferred to a cool-chassis session.
- **Quality-check on turboquant primary** — all 5 prompts correct (1099 math, list-comp, Macbeth, JSON, Mongolia capital).
- **`make audit-offline` on primary** — zero non-localhost sockets.
- **Vision e2e** — `qwen36-neo` + mmproj on `:10503`, base64 PNG → coherent reply in 2.8 s (clears the Round 6 deferred item).
- **Web demo + python demo** — both still talk to the live primary.
- **Editor configs** — `continue.json` and `opencode.json` re-confirmed; baseline / turboquant / fallback servers all live this session; launchd plist still healthy; symlink strategy verified.
- **100 K-needle long-context recall pass** — live primary `qwen36-neo` turbo3 @131 K recovered the secret password (`fjord-mango-pinwheel-9421`) from a 72 546-token prompt at depth 50 % in 1654 s wall (43.9 tok/s prefill, 4.5 tok/s gen). Reply was exact match. Prefill was about half the cool-chassis rate because the system was under heavy compressed-swap pressure (25.8 / 27 GiB used) from the bench-summarizer orphan-server incident; recall correctness held regardless. Recorded in `benchmarks/RESULTS.md`.
- **Smaller needle probes (same session)** — 5 K @ depth 50 %: recovered, 96 tok/s prefill, 48 s wall. 30 K @ depth 50 %: recovered, 93 tok/s prefill, 202 s wall.
- **Summarizer bench across 3 candidates** — `scripts/bench-summarizer.sh` ran gemma4-e4b vs nemotron-4b vs tiny on 5 inline fixtures, ~4.5 min wall, primary on `:10501` undisturbed. Result: **nemotron-4b recommended** (mean 13.93 s wall, 42.7 gen tok/s, ~2.8 GB VRAM, dense + faithful prose) over gemma4-e4b (14.16 s, 33.0 tok/s, ~8 GB, more polished but ~3× the VRAM for ~equivalent quality). `tiny` produced unusable token-salad on every fixture (suspect chat-template mismatch on the q8_0 head-dim-incompatible build) — do not use. `proxy/config.yaml` carries the recommendation in a comment; default `model:` flips to `nemotron-4b` once Phase 2 wires end-to-end.

## v0.0.1

Initial public release of the Apple Silicon Qwen 3.6 + llama.cpp + TurboQuant stack.

### Added

- Make targets for building mainline llama.cpp and the TurboQuant fork.
- TurboQuant, baseline, fallback, vision, and per-model start scripts.
- Offline browser and terminal chat clients.
- Model alias symlinking for LM Studio-downloaded GGUFs.
- Local status, info, healthcheck, benchmark, long-context needle, and quality-check scripts.
- Documentation for offline operation, API usage, multimodal requests, model selection, context sizing, and troubleshooting.
- Public-readiness checks via `make check` and setup diagnostics via `make preflight`.

### Verified

- TurboQuant Metal kernels load on Apple M3 Max.
- Qwen3.6-35B-A3B Q6_K runs at 64K context with TurboQuant KV cache.
- Long-context needle recovery works around 50K prompt tokens in the recorded benchmark.
- `llama-server` uses only localhost sockets during offline validation.

### Added (post-tag, pre-publish)

- `LICENSE` — MIT, with attribution notes for upstream `llama.cpp` and `llama-cpp-turboquant`.
- `SECURITY.md` — scope, reporting, and the headline guarantee (`make audit-offline`).
- `docs/install-models.md` — how to use the stack without LM Studio (`MODELS_ROOT=...` and direct `MODEL=/path/to/file.gguf`).
- `scripts/symlink-models.sh` — `MODELS_ROOT` env var to point at a custom GGUF directory.
- `benchmarks/quality-*/` is now gitignored. The aggregate numbers stay in `benchmarks/RESULTS.md` + `SWEEP.md`; per-prompt outputs are regenerated on demand via `make` targets.

### Known Limits

- The workflow CI file is not yet published because pushing `.github/workflows/*` requires GitHub credentials with `workflow` scope.
- Model files are not included; users must download GGUFs separately (see `docs/install-models.md`) or point `MODEL` at existing local files.
