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

## KV cache options ranked for this hardware

| KV type | Source | Metal? | Bytes/token (35B) | Use |
|---|---|---|---|---|
| f16 | mainline | yes | ~80 KB | baseline, max quality |
| q8_0 | mainline | yes | ~40 KB | safe context booster |
| q4_0 | mainline | yes | ~20 KB | last resort if memory tight |
| turbo2/3/4 | TurboQuant fork | **unverified** | ~10–20 KB | the prize, if it works |

Numbers approximate — depends on n_kv_head, head dim, and layer count.

## Memory budget on M3 Max 64 GB

- macOS + system: ~6 GB
- LM Studio idle: ~1 GB
- Q6_K weights (mmap): ~28.5 GB
- Compute graph + scratch: ~2–4 GB
- → KV cache budget: **~25 GB** before paging

That budget puts comfortable f16 ctx at ~32K, q8_0 at ~64K. turbo3, if it works, should stretch to 128K+.
