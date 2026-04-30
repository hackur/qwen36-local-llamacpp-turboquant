# Contributing

This project is optimized for local Apple Silicon inference. Keep changes focused on reproducible local setup, clear docs, and scripts that work from a clean clone.

## Before a PR

Run:

```bash
make check
```

If your change touches model paths or startup behavior, also run:

```bash
make preflight
./scripts/symlink-models.sh --dry-run
MODEL=tiny CTX=2048 KV=q8_0 PORT=10999 ./scripts/start-turboquant.sh --dry-run
```

## Model Paths

Do not commit model files, local symlinks, personal paths, logs, tokens, or generated runtime output. `models/`, `vendor/`, and `logs/` are intentionally ignored.

When adding a model alias, update:

- `scripts/symlink-models.sh`
- `docs/models.md`
- `docs/usage.md` if the model needs custom launch or API notes
- `docs/troubleshooting.md` if it has known KV-cache or chat-template quirks

## Benchmarks

Benchmark submissions should include:

- hardware and macOS version
- model filename and quantization
- llama.cpp fork and commit
- context length and KV cache type
- prompt/gen token rates
- whether the server was cold or warm

Avoid raw logs that contain local usernames, absolute private paths, or machine-specific process tables.
