# Changelog

## Unreleased

### Changed

- **Default model swapped** from `qwen36-35b` (Qwen3.6-35B-A3B Q6_K MoE) to `qwen36-neo` (Qwen3.6-27B Heretic-Uncensored NEO-CODE Q5_K_M dense, ~19.5 GB). Native 256K context (`n_ctx_train`), uncensored, code-tuned. `qwen36-35b` is preserved as `MODEL_FALLBACK` in `scripts/_common.sh`.
- `scripts/demo-chat.sh` rewritten as `scripts/demo-chat.py` (stdlib-only Python module). The shell file is now a one-line shim. Fixes three real bugs: invisible thinking output, C0-control corruption of streamed markdown, and phantom replies on bare-Enter input.
- `scripts/static-check.sh` now also runs `python3 -m unittest discover -s tests`.
- **Per-model defaults system.** `scripts/start-turboquant.sh` now resolves CTX/RoPE/etc. via `load_model_defaults` (in `scripts/_common.sh`) sourcing `configs/model-defaults.env`. Precedence: explicit env > per-model default > generic default > script-default.
- **Default CTX for `qwen36-35b` raised 131072 → 262144** (its `n_ctx_train` cap). Measured turbo3 KV at 256K is 1344 MiB — much lower than the 11.6 KiB/tok @64K extrapolation predicted, since turbo3's fixed overhead amortizes at large context.
- **KV-cache math corrected.** `docs/kv-cache-math.md`, `docs/architecture.md`, and `docs/context-matrix.md` previously claimed Qwen3.6-35B-A3B was 64 layers / 8 KV heads / head_dim 128 (~80 KB f16/tok). Actual GGUF metadata: 40 blocks / 2 KV heads / head_dim 256, with `full_attention_interval=4` → only 10 layers carry KV → ~20 KiB f16/tok. The 4× error meant the doc-reported "max 32K @ f16" was actually closer to 256K. All three docs corrected.
- `docs/system-info.md` date refreshed 2026-04-27 → 2026-05-06.
- `docs/troubleshooting.md` gained sections for proxy port `:11500`, run-to-run variance, mixed-K/V slowdown, port-guard, and privacy-gate failures.
- `docs/install-models.md` cosmetic skip-message wording fix.

### Added

- `start-qwen36-neo` Makefile target.
- Compaction reverse proxy at `proxy/` (Node/Fastify, `:11500` → `:10501`) with passthrough/shadow/enforce modes, Tier-1 elision (tool-result truncation + `expand_tool_result` phantom tool), and per-request JSONL logging. Operator quickstart in `docs/proxy.md`.
- Make targets: `proxy-install`, `proxy-test`, `proxy-start`, `proxy-smoke`.
- `summarizeElidedIds()` helper in `proxy/src/tier1.js` to bound `x-rewrite-stats` response-header size.
- Replay + needle eval harness under `proxy/eval/` (50-turn fixture, regex grader, mock-proxy tests).
- Proxy unit + stub-upstream integration tests under `proxy/tests/`.
- `tests/test_demo_chat.py` (33 stdlib-only cases for the REPL).
- `docs/demo-chat.md` user reference for the rewritten REPL.
- Round-4 / Round-5 / Round-6 sections in `HANDOFF.md`.
- `qwen36-neo` rows in `benchmarks/SWEEP.md` and `docs/kv-cache-math.md` with measured KV-cache footprints (15.2 KiB/tok at turbo3, ~22.7 GB total VRAM @ 256K).
- `configs/model-defaults.env` — per-model default knobs (CTX, RoPE flags, etc.).
- `scripts/_common.sh::load_model_defaults` and `scripts/_common.sh::rope_args` helpers, wired into `scripts/start-turboquant.sh`.
- **RoPE/YaRN escape-hatch** for one-shot context extension past `n_ctx_train`. Env vars `ROPE_SCALING`, `ROPE_SCALE`, `YARN_ORIG_CTX` plumbed through `start-turboquant.sh` as `--rope-scaling --rope-scale --yarn-orig-ctx`. Intended workflow (transient YaRN-2× server → compact-to-JSON → reload in fresh un-scaled session) documented.
- **Compact-and-save workflow** verified end-to-end (7-message synthetic conversation → 1.4 KB JSON → fresh session recovers all facts). New `snapshots/` directory convention (gitignored).
- **Vision memory pre-flight** in `scripts/start-vision.sh`: estimates total need (model GGUF + mmproj + 1.5 GiB KV scratch + summed RSS of other running `llama-server` PIDs + 4 GiB headroom) vs `hw.memsize`; aborts unless `FORCE=1`. Sentinel `# memory-preflight:v1`.
- **Privacy pre-push hook (opt-in).** `scripts/privacy-scan.sh` extracted from `static-check.sh`; `scripts/git-hooks/pre-push` available as a manual symlink (not auto-installed). `Makefile` targets `privacy-scan` and `prepush`. `CONTRIBUTING.md` updated with the symlink one-liner.
- `# port-guard:v1` sentinel in `_common.sh`'s `ensure_port_free`.
- `proxy/eval/ab-harness/` scaffold.

### Fixed

- `proxy/python/compact.py`: short prose under the token budget no longer collapses to a single sentence — fast-path passes through verbatim. Regression covered by a new test.
- `proxy/src/server.js` `sniffUsage()`: previously a flat regex (`\{[^}]*\}`) that bailed at the first inner `}`, so `completion_tokens` was always logged as `null` for real llama-server responses (which nest `prompt_tokens_details` inside `usage`). Replaced with a brace-balancing parser that handles nested objects, escaped quotes, and braces inside string content. Regression covered by `proxy/tests/sniff-usage.test.js` (7 cases).
- `scripts/start-turboquant.sh`: `${ROPE_FLAGS[@]}` under `set -u` blew up on macOS bash 3.2 when the array was empty (the no-RoPE common case), causing the launchd-managed primary to spin-restart. Both occurrences now use `${ROPE_FLAGS[@]+"${ROPE_FLAGS[@]}"}`.

### Verified live (proxy round-trip against llama-server :10501)

- Basic chat (non-streaming + SSE).
- Tool calling: function definitions forward, `tool_calls` come back, `tool_choice:"auto"` honoured. Streaming tool-call deltas pass through with `[DONE]` terminator.
- Tool-result round-trip: assistant `tool_calls` + `role:"tool"` reply + follow-up assistant message all produce a grounded answer.
- Tier-1 elision under live conditions: 44 K-token request with a 36 KB tool result outside the verbatim window compacted to 36 K tokens (`elided_tool_result_ids:["call_BIG"]`), original persisted to `~/.cache/qwen-compact/tool-results/<id>.json`, stub message carries `<tool_result id=... bytes=N first_lines=...>` preview.
- `expand_tool_result` phantom-tool interception: assistant call to `expand_tool_result(id=...)` is answered locally from the cache before the upstream sees it; `phantom_answered:["call_X1"]` recorded in the JSONL row.
- `proxy/tests/integration.sh` extended with two new checks (non-streaming tool call, tool-result round-trip, plus an `x-debug-rewritten` contract check). Suite: 9/9 pass against live `:10501` + `:11500`.

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
