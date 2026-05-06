# Sweep results — Qwen3.6-35B-A3B Q6_K · M3 Max 64 GB · macOS 26.4.1

## llama-bench: KV cache type cross-product

`llama-bench -p 512 -n 128 -r 2 -fa 1` with `-ctk` × `-ctv ∈ {f16, turbo3}`:

| K | V | pp512 (prompt tok/s) | tg128 (gen tok/s) |
|---|---|---|---|
| f16 | f16 | 880 ± 16 | 54.84 ± 0.82 |
| f16 | turbo3 | 536 ± 2 | 44.94 ± 1.03 |
| turbo3 | f16 | 376 ± 3 | 45.65 ± 0.13 |
| **turbo3** | **turbo3** | **1015 ± 17** | **52.96 ± 3.67** |

**Two surprises:**

1. **turbo3/turbo3 is faster than f16/f16 on prompt processing** (+15%). The smaller KV reads more than pay for the LUT dequant.
2. **Mixing types is much worse than either pure config.** The kernel has fast paths for {f16,f16} and {turbo3,turbo3}; mixed runs fall onto a slow generic path. **Always set `-ctk` and `-ctv` to the same value.**

Generation difference (turbo3 vs f16): 52.96 vs 54.84 → **-3.4%** — matches the server benchmark within noise.

## Multi-depth needle-in-haystack (turbo3, ~50 K tokens)

| Needle position | prompt_n | prompt tok/s | gen tok/s | wall | Recovered? |
|---|---|---|---|---|---|
| 5% (near start) | 44 486 | 605 | 37.0 | 74.0 s | ✅ |
| 50% (middle) | 28 102 | 480 | 34.2 | 64.0 s | ✅ |
| 95% (near end) | 28 102 | 339 | 31.8 | 89.2 s | ✅ |

All three depths recovered the exact password (`fjord-mango-pinwheel-9421`). KV-cache compression preserves recall across the entire window.

(prompt_n varies by depth because the script's 4-chars/token estimate rounds differently — same total content, equally hard recall task.)

## TTFT (time-to-first-token) at 4 prompt sizes — TurboQuant

| Prompt size (tokens) | TTFT | Effective prompt rate |
|---|---|---|
| 41 | 159 ms | 295 tok/s |
| 516 | 460 ms | 1 173 tok/s |
| 5 016 | 4 160 ms | 1 212 tok/s |
| 20 516 | 24 841 ms | 829 tok/s |

Prompt processing scales near-linearly above ~500 tokens. The bench harness adds chat-template overhead vs the raw `pp512` from llama-bench (1015 tok/s) — that gap is mostly the Jinja chat template render.

## Sustained generation A/B (server, hot, 3-run avg, 500-token gen)

| Profile | Gen tok/s | Prompt tok/s | Context |
|---|---|---|---|
| baseline f16 | 63.25 | 322 (hot) | 32 K |
| **turboquant turbo3** | **61.45** | 322 | **64 K** |

Only ~3% gen penalty for **2× the working memory window**.

## Quality spot-check (5 prompts, turbo3)

All 5 prompts produced correct, well-formed answers:

| # | Prompt | Result |
|---|---|---|
| 1 | `23 * 47 + 18` | `1099` ✓ (correct) |
| 2 | refactor python loop | List comprehension, `map()`, NumPy alternatives — exemplary |
| 3 | Macbeth in 3 sentences | Accurate plot summary |
| 4 | Extract JSON from sentence | `{"name":"Sarah","age":34,"city":"Berlin"}` ✓ |
| 5 | Trick question / Mongolia | Correctly answered "Ulaanbaatar" |

Outputs in `benchmarks/quality-20260428-094330/`.

## Memory observed at runtime

```
recommendedMaxWorkingSetSize  = 55 662 MB
| memory breakdown [MiB] | total | free | self  | model | context | compute |
| MTL0 (Apple M3 Max)    | 53084 | 53020 | 28016 | 26784 |   742   |   489   |
```

KV cache @ 64 K turbo3 = 742 MiB → ~12 KiB/tok. f16 at 64 K would be ~16 GiB → 22× compression. Detail: [`docs/kv-cache-math.md`](../docs/kv-cache-math.md).

## What we did NOT measure

- Battery vs AC throttling: would require unplugging the user's machine.
- Concurrent requests at -np > 1: server starts with -np 1 by design (single-user offline use case). Easy to re-test.
- Speculative decoding with a draft model: requires Qwen2-0.5B GGUF and `-md` flag — left as a follow-up.
- TURBO_SPARSE_V=0 ablation: the default value works; ablation pending if quality regressions appear in real workloads.

## qwen36-neo (Qwen3.6-27B Heretic NEO-CODE Q5_K_M)

Dense, ~19.5 GB weights. Hybrid Qwen3.6 architecture: 16 of 64 layers carry KV (attn + Gated Delta Net). Native `n_ctx_train = 262144` — no rope-scaling. Settings: `--ngl 99 -fa` on, turbo3 K+V, `--jinja`, sampling `temp=0.6 top_p=0.95 top_k=20`, thinking off.

### Memory observed at runtime

| Component | 128K | 256K |
|---|---|---|
| Weights (GPU + CPU) | 18 626 + 833 MiB | 18 626 + 833 MiB |
| KV cache (turbo3) | 1 944 MiB | 3 888 MiB |
| Recurrent state | 149.62 MiB | 149.62 MiB |
| **Total VRAM** | **20.4 GB** | **22.7 GB** |
| Free vs 53 GB Metal limit | 32.6 GB | 30.3 GB |

KV @ turbo3 = **15.2 KiB/tok** (vs ~64 KiB/tok at f16 measured by LM Studio on this same model). 4.2× compression — smaller ratio than the 35B-A3B's 22× because this dense Q5 model has fewer KV-carrying layers proportionally and a baseline f16 KV that's already tighter.

### Sustained generation (server, 3-run avg, 500-token gen)

| Profile | Gen tok/s | Prompt tok/s | Context |
|---|---|---|---|
| **turboquant turbo3** | **14** | 78 | **128K** |
| turboquant turbo3 | 7 | 53 | 256K |

Run-to-run variance @ 128K: 4.75–14.49 gen tok/s. Dense 27B at Q5 is the floor — the prior MoE 35B-A3B Q6_K hit 63 / 322 @ 64K because only ~3B params were active per token. Tradeoff: -78% gen, +100–300% context, uncensored + code-tuned.

### TTFT (time-to-first-token) at 4 prompt sizes

| Prompt size (tokens) | Wall | Prompt tok/s |
|---|---|---|
| 41 | 1.86 s | 67 |
| 512 | 6.27 s | 105 |
| 5 016 | 40.3 s | 127 |
| 20 516 | 157 s | 100 |

Prompt processing peaks ~127 tok/s in the 5K range, drops back to ~100 at 20K. KV writes dominate at long prompts.

### Capacity headroom

256K is the model's `n_ctx_train`. With 30 GB VRAM still free at 256K turbo3, the hardware is not the bottleneck — the trained context window is.
