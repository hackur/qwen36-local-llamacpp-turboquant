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

Qwen3.6-35B-A3B (per the GGUF metadata for `models/qwen36-35b.gguf`) has 40 transformer blocks, `n_head_kv = 2`, `key_length = value_length = 256`, and `full_attention_interval = 4` — so only 1-in-4 layers (10 of 40) carry an attention KV; the rest use Gated Delta Net recurrent state. For one (K,V) entry per attention-layer:

```
2 (K+V) × 10 KV-layers × 2 KV heads × 256 dim = 10 240 dimensions/token
```

So `742 MiB / 65 536 tok / 10 240 dim ≈ 1.16 bytes/dim ≈ 9.3 bits/dim`. (unverified — measurement pending: the 742 MiB figure includes turbo3 block overhead and the GDN recurrent state for the 30 non-attention layers, so this number is an upper bound on per-(K,V)-element storage rather than a clean bits-per-value reading.)

## Comparison table — same model (35B-A3B), different KV types

Estimated total KV memory at 64K context. The f16 baseline below is computed from the GGUF dims (10 KV-layers × 2 KV heads × 256 head_dim × 2 (K+V) × 2 bytes = 20 480 B/tok); q8_0 / q4_0 are ~4× / ~8× compressed plus small per-block overhead. The turbo3 row is **measured** from the run above; turbo2 is extrapolated. (unverified — measurement pending for q8_0/q4_0/turbo2 on this exact model.)

| KV type | bits/value (nominal) | bytes/token | KV @ 64K | KV @ 128K |
|---|---|---|---|---|
| f16 | 16 | ~20 KiB | ~1.25 GiB | ~2.5 GiB |
| q8_0 | 8 | ~10.5 KiB | ~0.66 GiB | ~1.3 GiB |
| q4_0 | 4 | ~5.5 KiB | ~0.34 GiB | ~0.68 GiB |
| **turbo3** | **~3** | **~11.6 KiB** (measured) | **0.74 GiB** ✅ | **~1.5 GiB** |
| turbo2 | ~2 | ~8 KiB | ~0.5 GiB | ~1 GiB |

(numbers approximate — actual depends on n_kv_head, sparse-V density, and runtime layout. Note that on this hybrid architecture, attention KV is small enough that turbo3 is roughly on par with f16 by raw KV bytes; turbo3's wins are in compute/bandwidth, not KV memory, for the 35B-A3B specifically.)

## qwen36-neo (Qwen3.6-27B Heretic NEO-CODE Q5_K_M) — measured

Same hybrid Qwen3.6 architecture (attn + Gated Delta Net, **16 of 64 layers carry KV** — `full_attention_interval = 4` in the GGUF metadata; the 35B-A3B uses the same 1-in-4 ratio, just over fewer total blocks: 10 of 40). Dense vs MoE only changes the FFN; attention dims are independent. Measured from server logs:

| Context | KV cache (turbo3) | bytes/token |
|---|---|---|
| 128K | 1 944 MiB | **15.2 KiB/tok** |
| 256K | 3 888 MiB | **15.2 KiB/tok** |

f16 KV on this same model (measured by LM Studio): **~64 KiB/tok** — which matches the GGUF math: 2 (K+V) × 16 KV-layers × 4 KV heads × 256 head_dim × 2 bytes = 65 536 B/tok. So turbo3 vs f16 here is **~4.2× compression**. The 35B-A3B has 4× fewer KV-heads (2 vs 4) and fewer KV-layers (10 vs 16), so its absolute f16 KV-per-token is much smaller (~20 KiB/tok); turbo3's relative win on the 35B is therefore correspondingly smaller, not larger.

Recurrent state (constant 149.62 MiB regardless of ctx) accounts for the 48 non-KV layers' Gated Delta Net state — fixed-size, doesn't scale with tokens.

## What this enables on this hardware

M3 Max has **55.6 GB** recommended max GPU working-set. With 35B-A3B Q6_K weights at **26.8 GB**, ~28 GB remains for KV + scratch:

- f16 (~20 KiB/tok): ~28 GB / 20 KiB ≈ 1.4M tokens
- q8_0 (~10.5 KiB/tok): ~28 GB / 10.5 KiB ≈ 2.7M tokens
- turbo3 (~11.6 KiB/tok measured): ~28 GB / 11.6 KiB ≈ 2.4M tokens

In every case the model's `n_ctx_train = 262 144` caps practical use long before memory does, so on this Mac for the 35B-A3B **the model's training context is the bottleneck, not the hardware** — we could comfortably run the full 256K window with any of these KV types. (For qwen36-neo at f16/64 KiB-per-tok the numbers tighten — see the matrix in `docs/context-matrix.md`.)

## Why this matters

For long-context use cases — repo-scale code review, multi-document RAG, long-running agent transcripts — the KV cache is what runs out first. TurboQuant moves the bottleneck from "memory" to "compute time" (still ~25s to prefill 20K tokens — unverified, measurement pending), which is a *good* trade because compute scales linearly while memory failure is binary (OOM kills the request).
