# qwen-compact-proxy

Phase 0 of the compaction proxy described in `../docs/compaction-strategy.md`.
This phase is a **transparent passthrough** with instrumentation: it forwards
every request to upstream `llama-server` byte-for-byte, but tokenizes the
incoming messages and writes a per-request JSONL log so we can tune watermarks
on real session data before any compaction logic lands.

## Run

```
cd proxy
npm install
npm start            # listens on :11500, forwards to :10501
```

Sit it in front of a running `llama-server`:

```
scripts/start-turboquant.sh &     # :10501
cd proxy && npm start &           # :11500
# point your OpenAI-compatible client at http://127.0.0.1:11500
```

## Endpoints

| Route                          | Behavior                                           |
| ------------------------------ | -------------------------------------------------- |
| `POST /v1/chat/completions`    | Passthrough; SSE preserved including `[DONE]`.     |
| `GET /v1/models`               | Passthrough.                                       |
| `GET /health`                  | Passthrough.                                       |
| `GET /proxy/info`              | Proxy state: mode, upstream, `n_ctx`, watermarks.  |
| anything else                  | Passed through to upstream verbatim.               |

Every response carries an `x-proxy-request-id` header (matches the JSONL log).

## Headers

- `x-compact: off` — bypasses any future compaction; logged so we can split
  before/after metrics. In Phase 0 this is informational only.

## Config (`proxy/config.yaml`)

| Key                          | Default                       | Notes                                                 |
| ---------------------------- | ----------------------------- | ----------------------------------------------------- |
| `listen.host`                | `127.0.0.1`                   |                                                       |
| `listen.port`                | `11500`                       |                                                       |
| `upstream.base_url`          | `http://127.0.0.1:10501`      | turboquant primary                                    |
| `upstream.request_timeout_ms`| `600000`                      | non-stream only                                        |
| `mode`                       | `passthrough`                 | `shadow` / `enforce` reserved for Phase 1+            |
| `watermarks.*`               | see file                      | unused in Phase 0; defaults match the design doc      |
| `cache_dir`                  | `~/.cache/qwen-compact`       | JSONL logs go to `<cache_dir>/logs/YYYY-MM-DD.jsonl`  |
| `tokenizer.cache_entries`    | `4096`                        | LRU keyed by exact string                             |
| `log_level`                  | `info`                        | pino level for stdout                                 |

Env overrides: `QWEN_COMPACT_PORT`, `QWEN_COMPACT_UPSTREAM`, `QWEN_COMPACT_MODE`,
`QWEN_COMPACT_CONFIG`.

## JSONL log fields

```
{ timestamp, request_id, model, mode, compact, stream,
  message_count, prompt_tokens, completion_tokens, status, latency_ms }
```

`completion_tokens` and `prompt_tokens` are taken from upstream's `usage` block
when present; otherwise `prompt_tokens` is computed locally via `/tokenize` and
`completion_tokens` is `null`.

## Tests

```
npm test                          # unit + stub-upstream integration
tests/integration.sh              # against real llama-server on :10501
```
