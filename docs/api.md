# API surface — what works against this server

Tested against `vendor/llama-cpp-turboquant/build/bin/llama-server` on `127.0.0.1:10501` with Qwen3.6-35B-A3B Q6_K loaded.

| Endpoint | Method | Status | Use |
|---|---|---|---|
| `/health` | GET | **200** | Liveness probe (returns `{"status":"ok"}`) |
| `/v1/models` | GET | **200** | OpenAI model list. Includes `meta.n_ctx_train` (262144 here) |
| `/props` | GET | **200** | Server config dump (chat template, default sampling, etc.) |
| `/slots` | GET | **200** | Per-slot state — useful when running -np > 1 |
| `/tokenize` | POST | **200** | `{"content":"hello"}` → `{"tokens":[...]}`. Useful for context budgeting. |
| `/detokenize` | POST | **200** | inverse |
| `/v1/chat/completions` | POST | 400 → 200 with body | Standard OpenAI chat. Streaming via `stream:true`. |
| `/v1/completions` | POST | 400 → 200 with body | Legacy OpenAI completion endpoint |
| `/completion` | POST | 400 → 200 | llama.cpp-native completion endpoint |
| `/metrics` | GET | 501 | Disabled by default. Add `--metrics` to llama-server to enable Prometheus. |
| `/v1/embeddings` | POST | 501 | Model isn't an embedding model. Load a separate embedder if you need this. |
| `/infill` | POST | 500 | Model isn't a fill-in-the-middle model |

## Per-model API quirks

Chat templates differ between families. The same JSON payload behaves differently depending on which model is loaded:

| Field | Qwen 3.5 / 3.6 | Gemma 4 | GPT-OSS 20B | TinyLlama / Nemotron |
|---|---|---|---|---|
| `chat_template_kwargs.enable_thinking` | ✅ — toggles `<think>` blocks | ignored | ignored | ignored |
| System role | supported | supported | supported | supported (limited) |
| Tool calling | ✅ via Qwen function-calling format | partial | ✅ OpenAI format | not really |
| Vision (image_url content) | ✅ with mmproj | ✅ with mmproj | ✗ | ✗ |
| `response_format: json_object` | ✅ | ✅ | ✅ | ✅ |
| `response_format: json_schema` | ✅ | ✅ | ✅ | ✅ |

`response_format` is enforced server-side via grammar-constrained sampling, not by the model. It works for any loaded model. See [`docs/usage.md`](usage.md#json--structured-output) for examples.

## Useful payloads

### Standard chat with thinking off (the way we benchmarked)

```bash
curl -s http://127.0.0.1:10501/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "local",
    "messages": [{"role":"user","content":"hello"}],
    "max_tokens": 256,
    "chat_template_kwargs": {"enable_thinking": false}
  }'
```

### Streaming

Add `"stream": true` to the body. Response is `text/event-stream` with `data: {...json...}` lines and a terminal `data: [DONE]`.

### Long context with TurboQuant

The server already started with `-c 65536` (or whatever you set via `CTX=`); just send a long prompt. Reported `n_ctx_train: 262144` is the model's training-time max — practical max depends on KV cache memory budget.

### Tokenize before you send

```bash
curl -s http://127.0.0.1:10501/tokenize \
  -H "Content-Type: application/json" \
  -d '{"content":"how many tokens am I?"}' | jq '.tokens | length'
```

## TTFT (time-to-first-token), measured

Single client, no warmup, 1-token max output:

| Prompt size (tokens) | TTFT | Effective prompt rate |
|---|---|---|
| 41 | 159 ms | 295 tok/s |
| 516 | 460 ms | 1 173 tok/s |
| 5 016 | 4 160 ms | 1 212 tok/s |
| 20 516 | 24.8 s | 829 tok/s |

Prompt processing is highly batched — small prompts under-utilize the GPU. Above ~500 tokens of prompt the rate stabilizes near ~1.2k tok/s on M3 Max with TurboQuant.

## Embedding companion (if you need it)

llama-server can only serve one model. For embeddings, run a second server on a different port loading an embedding GGUF (e.g. `nomic-embed-text-v1.5.Q8_0.gguf`):

```bash
vendor/llama.cpp-mainline/build/bin/llama-server \
  -m /path/to/nomic-embed-text-v1.5.Q8_0.gguf \
  --embeddings --port 10510 --host 127.0.0.1
```

Then route `/v1/embeddings` traffic to `:10510` and chat to `:10501`.
