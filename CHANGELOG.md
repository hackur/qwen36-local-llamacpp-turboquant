# Changelog

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

### Known Limits

- The workflow CI file is not yet published because pushing `.github/workflows/*` requires GitHub credentials with `workflow` scope.
- No license has been selected yet.
- Model files are not included; users must download GGUFs separately or point `MODEL` at existing local files.
