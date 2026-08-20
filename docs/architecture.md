# Architecture

Two parallel inference paths against the same GGUF on disk, fronted by an OpenAI-compatible HTTP server. A/B-bench them, route real traffic to the winner.

```
                                   ┌─ ~/.lmstudio/models/.../Qwen3.8-27B-Q8_0.gguf (27.1 GiB, dense 27B — primary)
        GGUF on disk  ─────────────┤  ~/.lmstudio/models/.../Qwen3.6-35B-A3B-Q6_K.gguf (28.5 GB, MoE — fallback)
                                   └─ mmproj-Qwen3.8-27B-BF16.gguf (0.87 GiB, vision projector)

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

`scripts/_common.sh` sets `MODEL_PRIMARY=qwen38-27b` (Qwen3.8-27B Q8_0,
dense VLM) and `MODEL_FALLBACK=qwen36-35b`. The default TurboQuant launcher
uses Qwen3.8's native 262K context and embedded MTP head. Vision uses the same
weights and projector but leaves MTP off by default because that combined path
has less production mileage than text-only MTP.

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
- Q8_0 weights + BF16 projector (mmap): ~28 GB (Qwen3.8 primary)
- Compute graph + scratch: ~2–4 GB
- → KV cache budget: **~25 GB** before paging

Qwen3.8's full 262K window was live-tested at roughly 34.5 GiB process RSS.
TurboQuant rewrites the requested turbo3/turbo3 combination to effective
q8_0/turbo3 for this model's 24:4 GQA layout, preserving key-cache quality.
