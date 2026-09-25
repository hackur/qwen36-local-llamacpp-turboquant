# API

The server listens on `http://127.0.0.1:10501`.

| Endpoint | Purpose |
|---|---|
| `GET /health` | readiness |
| `GET /v1/models` | Qwen3.8 model metadata |
| `POST /v1/chat/completions` | streaming or non-streaming text/vision chat |
| `GET /props` | loaded context and server defaults |
| `GET /slots` | active slot state |
| `GET /metrics` | Prometheus metrics; enabled by default |
| `GET/POST /tools` | WebUI tool registry and invocation when tools are enabled |

The advertised model identifier is `qwen3.8-local`. The proxy, editor configs,
benchmarks, and examples use that identifier consistently.

The optional Node proxy listens on `http://127.0.0.1:11500` only after
`make proxy-start`. It forwards other paths and adds `GET /proxy/info`. Its
default `passthrough` mode does not compact requests; `shadow` measures a
rewrite, and `enforce` forwards it. API clients using `:10501` bypass it.
`GET /proxy/info` also reports whether the optional JEV classifier gate is
configured; it does not report classifier service health.

Embeddings and reranking are intentionally absent. llama.cpp documents
`--embedding` as a dedicated-embedding-model mode; using the Qwen3.8 chat/VLM
weights as a generic embedding service would not be a supported configuration.
