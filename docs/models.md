# Models on disk

Re-using LM Studio's downloads — no duplication.

| Path | Format | Size | Active params | Notes |
|---|---|---|---|---|
| `~/.lmstudio/models/lmstudio-community/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-Q6_K.gguf` | GGUF Q6_K | 28.5 GB | 3B / 35B (MoE) | **Primary**. Best quality + speed on M3 Max. |
| `~/.lmstudio/models/lmstudio-community/Qwen3.6-35B-A3B-GGUF/mmproj-Qwen3.6-35B-A3B-BF16.gguf` | mmproj BF16 | 0.9 GB | — | Vision projector, pair with primary. |
| `~/.lmstudio/models/unsloth/Qwen3.6-27B-GGUF/Qwen3.6-27B-UD-IQ2_XXS.gguf` | GGUF IQ2_XXS | 9.4 GB | 27B dense | Low-mem fallback (~10 GB RAM). |
| `~/.lmstudio/models/unsloth/Qwen3.6-27B-GGUF/mmproj-F32.gguf` | mmproj F32 | 1.8 GB | — | Vision projector for 27B. |

## Why 35B-A3B over 27B dense

35B-A3B is a Mixture-of-Experts model with **35 B total parameters but only ~3 B active per token**. On M3 Max:

- it loads ~3× heavier than the 27B (28 GB vs 9 GB) — fits 64 GB easily,
- it generates **faster** because per-token compute is ~3 B (vs 27 B dense),
- and quality is higher than the 27B dense.

So MoE-A3B is "have your cake and eat it" on a 64 GB unified-memory Mac. The 27B IQ2_XXS stays around purely for the case where another big app eats the RAM.

## Path stability risk

These paths live under `~/.lmstudio/`. LM Studio's auto-update has, historically, never moved already-downloaded model files, but a future major version could. Mitigations:

1. The start scripts source a single `_common.sh` so the paths are in one place.
2. We symlink-not-copy from `models/` → the actual files (see `scripts/symlink-models.sh`) so the project survives if LM Studio reorganizes.

## Override

Any start script accepts `MODEL=/path/to/other.gguf ./scripts/start-baseline.sh` to point at something else without code changes.
