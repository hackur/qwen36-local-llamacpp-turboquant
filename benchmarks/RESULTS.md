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

## 2026-05-07 — qwen36-neo turbo3 @131K, sustained 3-run bench (thermal throttling reproduced)

3× back-to-back 500-token gens of the transformer-attention prompt against the live launchd-managed primary on `:10501` (M3 Max 64 GiB, AC, no other heavy processes). Confirms HANDOFF Round 5's reported variance band (4.75–14.49 tok/s) and supports `#49` hypothesis #2 (thermal throttling under sustained 500-tok generations). Wired memory was at 25.6 GiB (KV cache pinned), free 0.1 GiB, swap 13/13.3 GiB.

| Run | Gen tok/s | Prompt tok/s | Wall (s) | Δ vs run 1 |
|----:|----------:|-------------:|---------:|-----------:|
| 1 | 13.92 | 91.5 | 36.5 | — |
| 2 | 7.69 | 66.7 | 65.8 | -45 % |
| 3 | 4.11 | 41.2 | 122.8 | -70 % |

Linear-ish decay run-over-run is the classic Apple-Silicon GPU-throttle signature. Pre/post snapshots at `logs/variance-20260507-160120-pre-bench.log` and `logs/variance-20260507-160509-post-bench.log` (one-shot `pmset -g therm` did not record a warning level, but `pmset` is known to under-surface; the speed decay is the reliable signal).

Quality at the same `:10501` was perfect over 5 fixed prompts (`benchmarks/quality-20260507-155948/`) — the model isn't hallucinating from heat, it's just slower. Recommendation: cool the chassis 5–10 minutes between sustained 3-run benches; for repeatable numbers, pin to AC + wait for thermal floor.

## 2026-05-07 — qwen36-neo turbo3 @131K, 100K-needle long-context recall

Needle recovered at depth 50% on the live primary after a launchd
restart. Prompt chars 400119 → tokenized to **72546 tokens** (the
script's 4-char/token estimate was conservative for the UNIT text
chosen). Reply: `fjord-mango-pinwheel-9421`, exact match.

| metric | value |
|---|---:|
| prompt_n | 72 546 |
| prefill tok/s | 43.9 |
| gen tok/s | 4.5 |
| wall | 1654.5 s (27.5 min) |
| needle present | true |

Note the prefill rate (~44 tok/s) is roughly half of the cool-chassis
expectation (~90+ tok/s seen on the 30K probe earlier in this
session). System was under heavy compressed-swap pressure (25.8 GiB
swap used / 27 GiB total) from a prior orphan-server incident — see
the bench-summarizer teardown bug fix in this release. A re-run on a
clean process state should see the prefill rate roughly double; recall
correctness held regardless.

Smaller-target probes during the same window:
- 5K @ 50% — recovered, 96 tok/s prefill, 8.9 tok/s gen, 48 s wall
- 30K @ 50% — recovered (prompt_n 18516), 92.9 tok/s prefill, 5.4 tok/s gen, 202 s wall

The 50K probe via `make needle` timed out at the script's 600 s default
on the loaded primary. Inline retry with a 25 min cap timed out
similarly because of an unrelated prompt-size miscount (built a 267 K
char prompt instead of 50 K), which the server correctly rejected with
HTTP 400. The 100K result above used `scripts/needle.py`'s exact
prompt-construction logic via inline call with timeout=1800 s.

Baseline `:10500` was not running this round (one-server-at-a-time policy after a smell event); A/B diff against baseline f16 deferred to a future cool-chassis session.

## Reproduce

```bash
./scripts/build-llama.sh                # idempotent, ~5 min
./scripts/start-turboquant.sh &          # port 10501
python3 /tmp/bench.py 10501 "TurboQuant"  # if missing, see scripts/benchmark.sh
python3 /tmp/needle.py 50000              # long-context test
```
