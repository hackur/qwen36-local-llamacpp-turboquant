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

## Pre-publish checklist

Before opening a PR or pushing to a public branch:

```bash
make check         # bash -n + privacy linter
make preflight     # tools, builds, model symlinks
make audit-offline # zero non-localhost sockets (only with a server up)
```

If any fails, fix and re-run. The privacy linter (`scripts/privacy-scan.sh`,
also invoked by `make check`) greps for personal paths, hostnames, and
credential-shaped strings — green should mean "safe to publish".

### Enable the pre-push hook

To make `git push` refuse to publish when the privacy scan is red, symlink
the repo's hook template into your local `.git/hooks/` once per clone:

```bash
ln -sf ../../scripts/git-hooks/pre-push .git/hooks/pre-push
```

The hook runs `make privacy-scan` and aborts the push on any match. We do
not auto-install it during `make build` — modifying `.git/` silently would
be hostile.

## Benchmarks

Benchmark submissions should include:

- hardware and macOS version
- model filename and quantization
- llama.cpp fork and commit
- context length and KV cache type
- prompt/gen token rates
- whether the server was cold or warm

Avoid raw logs that contain local usernames, absolute private paths, or machine-specific process tables.
