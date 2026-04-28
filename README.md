# qwen36-local-llamacpp-turboquant

Offline-first local AI on Apple Silicon. Runs **Qwen 3.6** through **llama.cpp** with optional **TurboQuant** KV-cache compression for huge context — built on the YouTube guide [_Ultimate Guide Local AI Setup (Qwen3.6 + LlamaC++ + TurboQuant)_](https://www.youtube.com/watch?v=5jkAlqbk66A) (`5jkAlqbk66A`).

## Why this exists

The fastest, most reliable local model that keeps working with the network off. Reuses the GGUFs already in LM Studio (no re-download), wraps them in a vanilla `llama-server`, and benchmarks a TurboQuant build alongside the stock build to quantify the long-context win on M3 Max.

## Status

Planning. See [PLAN.md](./PLAN.md) for the 41-task breakdown.

## Hardware

Apple M3 Max · 64 GB unified memory · macOS 26.4.1.

## Models (already on disk)

- `Qwen3.6-35B-A3B-Q6_K.gguf` (28.5 GB) — primary
- `Qwen3.6-27B-UD-IQ2_XXS.gguf` (9.4 GB) — low-mem fallback
- Both ship with `mmproj` for multimodal.

## Quickstart (target)

```bash
./scripts/build-llama.sh         # build mainline + TurboQuant fork (Metal)
./scripts/start-turboquant.sh &  # port 10501, 128K context
./scripts/demo-chat.sh           # talk to it
```

Off-network test:
```bash
networksetup -setairportpower en0 off
./scripts/demo-chat.sh
```

## Layout

```
docs/         architecture, models, troubleshooting, offline validation
scripts/      build, start-*, benchmark, healthcheck, demo
configs/      sampling, opencode/continue, launchd
clients/      python + html demos
benchmarks/   results JSON + RESULTS.md
vendor/       llama.cpp-mainline + llama-cpp-turboquant (gitignored)
```

## Caveat

TurboQuant's `-ctk turbo3` was published with CUDA results. The fork claims Metal support; if the turbo3 kernel falls back to CPU on Metal, the plan has a `q8_0` KV-cache fallback path that's fully supported and still doubles usable context vs f16.
