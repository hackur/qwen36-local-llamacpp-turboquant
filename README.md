# qwen36-local-llamacpp-turboquant

**Qwen 3.6** running fully offline on Apple Silicon, with **TurboQuant** KV-cache compression for 2× context at the same speed. Built around the YouTube guide [_Ultimate Guide Local AI Setup (Qwen3.6 + LlamaC++ + TurboQuant)_](https://www.youtube.com/watch?v=5jkAlqbk66A).

## Why use this instead of LM Studio

LM Studio is great for downloading models. It is **not** designed to keep working when you disconnect: it caches an account check (`lm-link-account-status-cache.json`) that re-validates online, and the hub catalog refreshes on every launch. Disconnect Wi-Fi → UI hangs or blocks features.

This stack is `llama.cpp`'s `llama-server` binary directly. No Electron, no telemetry, no account, no catalog. Verified on this M3 Max with `lsof`:

```
$ lsof -nP -p $(pgrep -f vendor/llama-cpp-turboquant.*llama-server) | grep TCP
llama-ser ... TCP 127.0.0.1:10501 (LISTEN)
```

One socket. Localhost. No outbound. **Wi-Fi off → no impact.**

See [`docs/offline-mode.md`](docs/offline-mode.md) for the full offline recipe.

## Real numbers — Qwen3.6-35B-A3B Q6_K on M3 Max 64GB

| Profile | KV cache | Context | Gen tok/s | Prompt tok/s | Notes |
|---|---|---|---|---|---|
| baseline | f16 | 32K | **63.25** | ~322 | mainline llama.cpp |
| **turboquant** | **turbo3** | **64K** | **61.45** | ~322 | -3% gen, +100% context |

Long-context recall: needle at 50K tokens **recovered exactly**. Server log confirms TurboQuant Metal kernels are live: `ggml_metal_library_init: turbo3 using 4-mag LUT (pre-M5 hardware)`.

Full results: [`benchmarks/RESULTS.md`](benchmarks/RESULTS.md).

## Quickstart

```bash
make build                    # one-time, ~5 min, Metal builds of both forks
make start                    # turboquant server on :10501
make open                     # opens clients/web-demo.html in your browser
```

Or double-click **`Qwen-Offline.command`** in Finder — starts the server and pops the web UI.

To make it auto-start at login (truly always-on offline):

```bash
make install-launchd
```

## What's running right now

```bash
make info        # one screen: env, server config, params, KV type, RSS,
                 # system memory, inbound/outbound sockets, disk usage,
                 # launchd state, last bench numbers
make info-watch  # same, refreshing every 2 s
```

The web demo also has an **info drawer** in the header (collapsed by default) with:
- active server (model, params, context loaded/trained, build SHA)
- this session (messages, user/assistant token estimates, last gen rate)
- live activity from `/slots` (idle / generating)
- sampling defaults from `/props`

## All targets

```
$ make
Targets:
  build               Build mainline + TurboQuant llama.cpp (Metal). Idempotent.
  start               Start default model (qwen36-35b) on :10501
  start-baseline      Start mainline f16 baseline (port 10500)
  start-tiny          TinyLlama 1.1B (smoke test) — uses q8_0
  start-nemotron      Nemotron-3 4B
  start-crow          Crow 9B (Qwen3.5 distill)
  start-gemma4-e4b    Gemma 4 E4B
  start-qwen35-9b     Qwen 3.5 9B
  start-gpt-oss       GPT-OSS 20B — uses q8_0
  start-gemma4-26b    Gemma 4 26B-A4B (MoE)
  start-qwen36-27b    Qwen 3.6 27B
  models              List every available model alias
  stop                Stop all llama-server processes from this repo
  status              What's running and where (terse)
  info                Full one-shot dashboard (env, server, memory, network, disk, launchd, last bench)
  info-watch          Same as `info`, refreshing every 2 s
  bench               Run A/B benchmark (assumes both servers up)
  needle              Long-context recall test on TurboQuant
  demo                Terminal chat REPL
  open                Open the web demo in your browser
  install-launchd     Install launchd auto-start (always-on offline)
  uninstall-launchd   Remove launchd auto-start
  clean               Wipe build artifacts (does NOT delete vendor/ source)
  audit-offline       Confirm llama-server has zero non-localhost sockets
```

## Hardware tested

Apple M3 Max · 64 GB unified memory · macOS 26.4.1.

## Hardware tested again

The 9-model picker above is the canonical "Models" section.

## Layout

```
README.md             this file
PLAN.md               original 41-task implementation plan
Makefile              ergonomic wrappers
Qwen-Offline.command  double-click launcher (Finder)
scripts/              build, start-*, stop-all, status, bench, needle, demo, healthcheck, symlink
clients/              python-demo.py · web-demo.html
configs/              opencode, continue, launchd plist, sampling
docs/                 architecture, offline-mode, multimodal, troubleshooting, references, …
benchmarks/           RESULTS.md + raw run logs
vendor/               llama.cpp-mainline + llama-cpp-turboquant (gitignored)
models/               symlinks to LM Studio GGUFs
logs/                 runtime logs (gitignored)
```

## Optional: weekly health check

If you want a recurring background agent to confirm nothing has regressed, you can use Claude Code's `/schedule` to run something like:

```
make audit-offline && make bench && make needle
```

…on a weekly cadence. Skip it unless you actually want the routine — the stack works without it.

## What this isn't

A model trainer, a fine-tuning toolkit, a MCP server, or a Cursor replacement. It's a **local inference server** with one job: serve Qwen 3.6 reliably with the network off, fast, on Apple Silicon.
