# Changelog

## Unreleased

### Changed

- **Default model swapped** from `qwen36-35b` (Qwen3.6-35B-A3B Q6_K MoE) to `qwen36-neo` (Qwen3.6-27B Heretic-Uncensored NEO-CODE Q5_K_M dense, ~19.5 GB). Native 256K context (`n_ctx_train`), uncensored, code-tuned. `qwen36-35b` is preserved as `MODEL_FALLBACK` in `scripts/_common.sh`.
- `scripts/demo-chat.sh` rewritten as `scripts/demo-chat.py` (stdlib-only Python module). The shell file is now a one-line shim. Fixes three real bugs: invisible thinking output, C0-control corruption of streamed markdown, and phantom replies on bare-Enter input.
- `scripts/static-check.sh` now also runs `python3 -m unittest discover -s tests`.

### Added

- `start-qwen36-neo` Makefile target.
- Compaction reverse proxy at `proxy/` (Node/Fastify, `:11500` → `:10501`) with passthrough/shadow/enforce modes, Tier-1 elision (tool-result truncation + `expand_tool_result` phantom tool), and per-request JSONL logging. Operator quickstart in `docs/proxy.md`.
- Make targets: `proxy-install`, `proxy-test`, `proxy-start`, `proxy-smoke`.
- `summarizeElidedIds()` helper in `proxy/src/tier1.js` to bound `x-rewrite-stats` response-header size.
- Replay + needle eval harness under `proxy/eval/` (50-turn fixture, regex grader, mock-proxy tests).
- Proxy unit + stub-upstream integration tests under `proxy/tests/`.
- `tests/test_demo_chat.py` (33 stdlib-only cases for the REPL).
- `docs/demo-chat.md` user reference for the rewritten REPL.
- Round-4 / Round-5 sections in `HANDOFF.md` documenting the model swap measurements and REPL rewrite.
- `qwen36-neo` rows in `benchmarks/SWEEP.md` and `docs/kv-cache-math.md` with measured KV-cache footprints (15.2 KiB/tok at turbo3, ~22.7 GB total VRAM @ 256K).

### Fixed

- `proxy/python/compact.py`: short prose under the token budget no longer collapses to a single sentence — fast-path passes through verbatim. Regression covered by a new test.
- `proxy/src/server.js` `sniffUsage()`: previously a flat regex (`\{[^}]*\}`) that bailed at the first inner `}`, so `completion_tokens` was always logged as `null` for real llama-server responses (which nest `prompt_tokens_details` inside `usage`). Replaced with a brace-balancing parser that handles nested objects, escaped quotes, and braces inside string content. Regression covered by `proxy/tests/sniff-usage.test.js` (7 cases).

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
