# Models on disk

Re-using LM Studio's downloads — no duplication. `scripts/symlink-models.sh` maps each into `models/<alias>.gguf` (and `<alias>.mmproj.gguf` when a vision projector exists).

## Picker

```bash
make models                       # list everything available
MODEL=<alias> make start          # or: MODEL=<alias> ./scripts/start-turboquant.sh
```

Or use a per-model Make target — these come with sensible defaults for KV cache and context:

| Target | Alias | What it loads |
|---|---|---|
| `make start` / `make start-qwen38` | `qwen38-27b` | **default**, dense Q8_0 VLM, native 262K, TurboQuant KV + embedded MTP |
| `make start-vision` | `qwen38-27b` | same model with its BF16 vision projector, MTP off by default |
| `make start-qwen36-neo` | `qwen36-neo` | legacy uncensored/code-tuned fallback |
| `make start-qwen36-27b` | `qwen36-27b` | dense 27B IQ2_XXS, 32K |
| `make start-gemma4-26b` | `gemma4-26b` | Gemma 4 26B-A4B MoE, 32K, turbo3 |
| `make start-gpt-oss` | `gpt-oss-20b` | OpenAI 20B MXFP4, 32K, **q8_0 KV** (turbo3 unsupported) |
| `make start-qwen35-9b` | `qwen35-9b` | Qwen 3.5 9B Q8_0, 32K |
| `make start-crow` | `crow-9b` | Crow 9B (Qwen3.5 distill), 16K |
| `make start-gemma4-e4b` | `gemma4-e4b` | Gemma 4 E4B Q8_0, 16K |
| `make start-nemotron` | `nemotron-4b` | NVIDIA Nemotron-3 4B, 8K |
| `make start-tiny` | `tiny` | TinyLlama 1.1B, 2K, **q8_0 KV** (turbo3 unsupported) |
| `make start-qwen3.5-0.8b` | `qwen3.5-0.8b` | Qwen 3.5 0.8B Q8_0, speculative-decoding draft / cold-start / battery mode |

## Full inventory

| Alias | Family | Params | Quant | Size | Vision (mmproj)? | turbo3? |
|---|---|---|---|---|---|---|
| `qwen38-27b` | Qwen 3.8 27B | dense | Q8_0 | 27.1 GiB | ✓ | ✓, effective q8_0/turbo3 |
| `qwen36-neo` | Qwen 3.6 27B Heretic NEO-CODE (uncensored, code-tuned) | dense | Q5_K_M | 19.5 GB | ✓ | ✓ |
| `qwen36-35b` | Qwen 3.6 35B-A3B | MoE 35B / 3B-active | Q6_K | 28.5 GB | ✓ | ✓ |
| `qwen36-27b` | Qwen 3.6 27B | dense | IQ2_XXS | 9.4 GB | ✓ | ✓ |
| `gemma4-26b` | Gemma 4 26B-A4B | MoE | Q4_K_M | 16.8 GB | ✓ | ✓ |
| `gemma4-e4b` | Gemma 4 E4B | dense | Q8_0 | 8.0 GB | ✓ | ✓ |
| `gpt-oss-20b` | OpenAI 20B oss | dense | MXFP4 | 12.1 GB | — | **✗ — use q8_0** |
| `qwen35-9b` | Qwen 3.5 9B | dense | Q8_0 | 9.5 GB | ✓ | ✓ |
| `crow-9b` | Crow 9B (Qwen3.5 distill) | dense | Q4_K_S | 5.3 GB | ✓ | ✓ |
| `nemotron-4b` | NVIDIA Nemotron-3 4B | dense | Q4_K_M | 2.8 GB | — | ✓ |
| `tiny` | TinyLlama 1.1B | dense | Q4_K_M | 0.7 GB | — | **✗ — use q8_0** |
| `qwen3.5-0.8b` | Qwen 3.5 0.8B | dense | Q8_0 | 0.78 GB | — | ✓ |

✓ in the turbo3 column means we verified the kernel loads and generates without error on M3 Max. The "✗" entries crash with `Abort trap: 6` during `graph_reserve` — turbo3's kernel doesn't yet support those head dims / quantization combinations, so the Make targets pin them to `KV=q8_0`.

## Smoke-tested generation rates (M3 Max, KV-cache type as listed)

| Alias | KV | Gen tok/s |
|---|---|---|
| qwen38-27b | effective q8_0/turbo3 + MTP | 24.60 (32K), full 262K load verified |
| qwen36-neo | turbo3 | 14 (128K) / 7 (256K) — dense Q5, see [`benchmarks/SWEEP.md`](../benchmarks/SWEEP.md#qwen36-neo-qwen36-27b-heretic-neo-code-q5_k_m) |
| qwen36-35b | turbo3 | 61–63 |
| gemma4-26b | turbo3 | 80.5 |
| gpt-oss-20b | q8_0 | 77.6 |
| qwen35-9b | turbo3 | ~50 (with thinking off) |
| crow-9b | turbo3 | 69.9 |
| gemma4-e4b | turbo3 | 51.1 |
| nemotron-4b | turbo3 | 98.0 |
| tiny | q8_0 | 272 |
| qwen3.5-0.8b | turbo3 | — (draft / cold-start) |

## Why we kept Qwen3.6 35B-A3B as a fallback

35B-A3B is a Mixture-of-Experts model with **35 B total parameters but only ~3 B active per token**. On M3 Max:

- it loads ~3× heavier than the 27B (28 GB vs 9 GB) — fits 64 GB easily,
- it generates **faster** because per-token compute is ~3 B (vs 27 B dense),
- and quality is higher than the 27B dense.

So MoE-A3B is "have your cake and eat it" on a 64 GB unified-memory Mac. The 27B IQ2_XXS stays around purely for the case where another big app eats the RAM.

## Why `qwen38-27b` is the default

Qwen3.8 replaces the older Qwen3.6 NEO-CODE model as the primary path because it combines the highest practical local quant on 64 GB, native 262K context, built-in vision, and an embedded MTP head in one model.

- **Q8 quality ceiling.** About 27.1 GiB of weights leaves responsible headroom on a 64 GB Mac; BF16 would not.
- **Embedded MTP.** Current TurboQuant measured 24.60 tok/s versus 11.90 tok/s without MTP on the same Q8 weights.
- **Native 262K context.** Full context loaded in 5.14 seconds at roughly 34.5 GiB RSS.
- **One multimodal model.** The matching BF16 projector handles screenshot and image work without changing base weights.

`qwen36-35b` remains `MODEL_FALLBACK`; `qwen36-neo` remains available for its uncensored/code-tuned behavior.

## Path stability risk

These paths live under `~/.lmstudio/`. LM Studio's auto-update has, historically, never moved already-downloaded model files, but a future major version could. Mitigations:

1. The start scripts source a single `_common.sh` so the paths are in one place.
2. We symlink-not-copy from `models/` → the actual files (see `scripts/symlink-models.sh`) so the project survives if LM Studio reorganizes.

## Override

Any start script accepts `MODEL=/path/to/other.gguf ./scripts/start-baseline.sh` to point at something else without code changes.
