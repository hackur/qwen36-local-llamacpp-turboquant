# Architecture

Two parallel inference paths against the same GGUF on disk, fronted by an OpenAI-compatible HTTP server. A/B-bench them, route real traffic to the winner.

```
                                   ┌─ ~/.lmstudio/models/.../Qwen3.6-35B-A3B-Q6_K.gguf  (28.5 GB, MoE 35B/3B-active)
        GGUF on disk  ─────────────┤
                                   └─ mmproj-Qwen3.6-35B-A3B-BF16.gguf                  (vision projector, optional)

                                   ┌─ vendor/llama.cpp-mainline (master)        ── Metal, f16 KV     ─ port 10500  baseline
        Inference engine  ─────────┤
                                   └─ vendor/llama-cpp-turboquant                ── Metal, turbo3 KV ─ port 10501  primary
                                       branch: feature/turboquant-kv-cache         (or q8_0 fallback)  port 10502  fallback

        HTTP surface  ──── OpenAI-compatible llama-server  (/v1/chat/completions, /v1/models, /health)

                                   ┌─ scripts/demo-chat.sh   curl + jq streaming TUI
        Clients (offline)  ────────┤   clients/python-demo.py  openai-python pointed at localhost
                                   ├─ clients/web-demo.html   single-file streaming chat
                                   └─ OpenCode / Continue / Zed via configs/
```

## Why two engines

The TurboQuant fork drifts from upstream slowly. Keeping a stock mainline build wired up on a separate port means:

1. Any time TurboQuant breaks against a new GGUF format, the baseline still works.
2. Every benchmark has a fair control on the same hardware against the same model file.
3. If `-ctk turbo3` falls back to CPU on Metal, the fallback (mainline + `q8_0` KV cache) still gets us 2–4× context vs f16.

## Default vs fallback model

`scripts/_common.sh` now sets `MODEL_PRIMARY=qwen36-neo` (Qwen3.6-27B Heretic NEO-CODE Q5_K_M, dense). The 35B-A3B MoE GGUF shown above is the **fallback** — kept wired up for A/B comparisons and as a quality reference. KV-cache numbers in the table below are for the 35B-A3B; for qwen36-neo see `docs/kv-cache-math.md`.

## KV cache options ranked for this hardware

Bytes/token below are derived from the GGUF metadata of `models/qwen36-35b.gguf`: `block_count = 40`, `head_count_kv = 2`, `key_length = value_length = 256`, `full_attention_interval = 4` → only 10 of 40 layers carry attention KV. The f16 baseline is `2 (K+V) × 10 KV-layers × 2 KV heads × 256 head_dim × 2 bytes = 20 480 B/tok`.

| KV type | Source | Metal? | Bytes/token (35B-A3B) | Use |
|---|---|---|---|---|
| f16 | mainline | yes | ~20 KiB | baseline, max quality |
| q8_0 | mainline | yes | ~10.5 KiB | safe context booster |
| q4_0 | mainline | yes | ~5.5 KiB | last resort if memory tight |
| turbo3 | TurboQuant fork | yes (measured) | ~11.6 KiB (measured @ 64K) | the prize |

Numbers approximate — depends on n_kv_head, head dim, layer count, and turbo3 block overhead. The 35B-A3B's hybrid architecture (Gated Delta Net on 30 of 40 layers) keeps absolute KV bytes small; turbo3's wins on this model are in compute/bandwidth more than KV memory.

## Memory budget on M3 Max 64 GB

- macOS + system: ~6 GB
- LM Studio idle: ~1 GB
- Q6_K weights (mmap): ~28.5 GB (35B-A3B fallback)
- Compute graph + scratch: ~2–4 GB
- → KV cache budget: **~25 GB** before paging

For the 35B-A3B, the model's `n_ctx_train = 262 144` caps practical use long before 25 GB of KV does — at 20 KiB/tok f16, 256K context is only ~5 GB. The full training window fits comfortably with any KV type (estimate — measurement pending for q8_0/q4_0/turbo2 ceilings).
