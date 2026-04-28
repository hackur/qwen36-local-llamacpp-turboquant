# KV cache memory math

Measured numbers from `start-turboquant.sh` (Qwen3.6-35B-A3B Q6_K, M3 Max, 64K ctx, turbo3 KV):

```
| memory breakdown [MiB] | total | free | self  | model | context | compute |
| MTL0 (Apple M3 Max)    | 53084 | 53020 | 28016 | 26784 |   742   |   489   |
```

- model weights on Metal: **26 784 MiB** (28 514 MB on disk, ~6 % expansion to GPU layout — expected)
- KV cache @ 64K turbo3: **742 MiB**
- compute scratch: **489 MiB**

## Bytes per token observed

KV cache holds K and V for every layer of every token in context.

```
742 MiB / 65 536 tokens ≈ 11.6 KiB / token
```

Qwen3.6-35B-A3B has 64 layers and `n_kv_head = 8` (grouped-query attention) per layer, head dim 128. For one (K,V) entry per layer:

```
2 (K+V) × 64 layers × 8 KV heads × 128 dim = 131 072 dimensions/token
```

So `742 MiB / 65 536 tok / 131 072 dim ≈ 0.09 byte/dim ≈ 0.71 bit/dim`.

That's *less* than a literal 2-bit quant — turbo3's "3" refers to nominal bits/weight; the storage layout adds overhead and the sparse-V dequantization further packs values that are near-zero.

## Comparison table — same model, different KV types

Estimated total KV memory at 64K context:

| KV type | bits/value (nominal) | bytes/token | KV @ 64K | KV @ 128K |
|---|---|---|---|---|
| f16 | 16 | ~256 KiB | ~16 GiB | ~32 GiB (won't fit) |
| q8_0 | 8 | ~128 KiB | ~8 GiB | ~16 GiB |
| q4_0 | 4 | ~64 KiB | ~4 GiB | ~8 GiB |
| **turbo3** | **~3** | **~12 KiB** | **0.74 GiB** ✅ | **~1.5 GiB** |
| turbo2 | ~2 | ~8 KiB | ~0.5 GiB | ~1 GiB |

(numbers approximate — actual depends on n_kv_head, sparse-V density, and runtime layout)

## What this enables on this hardware

M3 Max has **55.6 GB** recommended max GPU working-set. With weights at **26.8 GB**:

- f16 leaves ~28 GB → ~110K tokens (theoretical, before scratch)
- q8_0 leaves ~28 GB / 128 KiB-per-tok ≈ 225K tokens
- turbo3 leaves ~28 GB / 12 KiB-per-tok ≈ 2.4M tokens — *but* the model's `n_ctx_train` caps practical use at 262 144

So with TurboQuant on this Mac, **the model's training context is the bottleneck, not the hardware**. We could comfortably run the full 256K context window with room to spare.

## Why this matters

For long-context use cases — repo-scale code review, multi-document RAG, long-running agent transcripts — the KV cache is what runs out first. TurboQuant moves the bottleneck from "memory" to "compute time" (still ~25s to prefill 20K tokens), which is a *good* trade because compute scales linearly while memory failure is binary (OOM kills the request).
