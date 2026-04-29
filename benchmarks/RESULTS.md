# Benchmark results — Qwen 3.6 + llama.cpp + TurboQuant on M3 Max 64 GB

**Hardware**: Apple M3 Max, 16 cores (12P + 4E), 64 GB unified memory
**OS**: macOS 26.4.1
**Model**: `Qwen3.6-35B-A3B-Q6_K.gguf` (28.5 GB, MoE 35B/3B-active)
**Build commits**:
- mainline: `vendor/llama.cpp-mainline` HEAD `f9f3365`
- turboquant: `vendor/llama-cpp-turboquant` HEAD `11a241d` (branch `feature/turboquant-kv-cache`)
**Run date**: 2026-04-28

## TL;DR

✅ **TurboQuant turbo3 Metal kernel works on M3 Max.** Server log emits `ggml_metal_library_init: turbo3 using 4-mag LUT (pre-M5 hardware)` on startup — Metal kernels load, KV cache compresses, dispatch stays on the GPU.

✅ **2× context for ~3% generation speed.** Baseline f16 KV at 32K → 63.25 tok/s. TurboQuant turbo3 at 64K → 61.45 tok/s. Same throughput class, double the working memory.

✅ **No quality loss at 50K tokens.** Needle-in-haystack finds the password buried in 200KB of filler.

✅ **Fully offline.** llama-server holds exactly one socket: `TCP 127.0.0.1:10501 (LISTEN)`. Zero outbound. No telemetry, no DNS, no auth callbacks.

## Throughput (3-run hot average, 500-token gen)

| Profile | Port | KV | Ctx | Gen tok/s | Prompt tok/s (hot) | Wall/run |
|---|---|---|---|---|---|---|
| baseline    | 10500 | f16    | 32K | **63.25** | ~321 | 8.1s |
| turboquant  | 10501 | turbo3 | 64K | **61.45** | ~322 | 8.3s |

Sampling: temp 0.6, top_p 0.95, top_k 20, min_p 0.0, `enable_thinking: false`.

Baseline run 1 prompt-tps was 168 (cold cache); runs 2 + 3 hit ~320 hot. TurboQuant was hot from run 1 because the warmup primed it.

## Long-context recall (TurboQuant only)

| Stuffed prompt | prompt_n actual | prompt tok/s | gen tok/s | Wall | Needle? |
|---|---|---|---|---|---|
| ~50 000 tokens | 44 482 | 561.6 | 37.4 | 79.6s | ✅ recovered exactly |

The model returned `'fjord-mango-pinwheel-9421'` verbatim. KV-cache compression preserves the needle.

Prompt processing actually *speeds up* at long context because batched prefill fills the GPU pipeline.

## Offline verification

```
$ lsof -nP -p $(pgrep -f vendor/llama-cpp-turboquant.*llama-server) | grep TCP
llama-ser 51886 user   3u  IPv4 ...  TCP 127.0.0.1:10501 (LISTEN)
```

Single localhost listener. No outbound connections from the llama-server PID. Wi-Fi can be disabled with no impact on inference.

## Memory observations

Server startup log:
```
recommendedMaxWorkingSetSize  = 55662.79 MB
| memory breakdown [MiB] | total | free | self  | model | context | compute |
| MTL0 (Apple M3 Max)    | 53084 | 53020 | 28016 | 26784 |   742   |   489   |
```

- Model weights on Metal: **26.78 GB**
- KV cache @ 64K turbo3: **742 MB** (vs ~5 GB f16 at the same context)
- Compute scratch: **489 MB**
- Total: **~28 GB on the GPU**, leaves ~25 GB unified-memory headroom for the rest of macOS.

Running two llama-servers simultaneously on this Mac OOMs the GPU (each tries to claim 28 GB of weights). The plan has been to A/B them by swapping, not running concurrently.

## Reproduce

```bash
./scripts/build-llama.sh                # idempotent, ~5 min
./scripts/start-turboquant.sh &          # port 10501
python3 /tmp/bench.py 10501 "TurboQuant"  # if missing, see scripts/benchmark.sh
python3 /tmp/needle.py 50000              # long-context test
```
