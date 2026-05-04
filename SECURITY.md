# Security

This repository contains shell scripts and `Makefile` targets that build local
binaries (`llama.cpp` and a TurboQuant fork) and run a local HTTP inference
server on `127.0.0.1`. Read the relevant scripts before you run anything that
makes you nervous.

## Scope

In scope:

- A vulnerability in our own code: scripts under `scripts/`, clients under
  `clients/`, the `Makefile`, our config templates.
- A privacy regression: any change that re-introduces personal paths,
  hostnames, or secrets after the static-check linter green-listed them.
- Anything that causes `llama-server` started by our scripts to make network
  connections beyond `127.0.0.1`.

Out of scope (not this repo's bugs, but the upstream projects' — please file
there):

- `llama.cpp` itself: <https://github.com/ggml-org/llama.cpp/issues>
- `llama-cpp-turboquant` itself: <https://github.com/TheTom/llama-cpp-turboquant/issues>
- Apple Metal, macOS Gatekeeper, model weights from Hugging Face.

## Reporting

For private disclosure, open a [GitHub security advisory] on the repository.
Public, low-severity issues can also be filed as regular issues.

[GitHub security advisory]: https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability

## What this repo does NOT contain

- Model weights — every GGUF is symlinked from your local LM Studio cache (or
  a path you specify with `MODELS_ROOT`). Nothing is redistributed.
- Secrets, API keys, or tokens — clients pass `api_key=no-key` to a local
  server that doesn't check it.
- Telemetry — no analytics, no crash reports, no usage pings. Confirm with
  `make audit-offline`.

## Verifying offline operation yourself

```bash
make start
make audit-offline   # → "✓ zero non-localhost sockets — provably offline-clean"
```

If you ever see that probe fail, please file an issue immediately — that
would be a regression of the project's headline guarantee.

## Pre-commit / pre-publish check

```bash
make check        # bash -n on scripts + privacy linter
make preflight    # tools, builds, model symlinks
```

Both should be green before any `git push` to a public branch.
