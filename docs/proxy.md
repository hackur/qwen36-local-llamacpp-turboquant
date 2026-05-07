# Compaction proxy — quickstart

A transparent reverse proxy that sits between your OpenAI-compatible client and
`llama-server`, with hooks for context compaction. Design rationale and the full
phased plan live in [`compaction-strategy.md`](compaction-strategy.md). This page
is the operator's view: what it does today, how to run it, and how to read its
output.

## What it does

- Listens on `:11500` and forwards every request to `llama-server` on `:10501`.
- SSE streams pass through verbatim, including `[DONE]`.
- **Tool calling works unchanged** — function definitions, `tool_calls`,
  `tool_choice`, and tool-result messages round-trip through the proxy. Both
  streaming and non-streaming forms are covered by `proxy/tests/integration.sh`.
- Tokenizes the incoming `messages` array via the upstream `/tokenize` endpoint
  and writes a per-request JSONL log line (`prompt_tokens`, `completion_tokens`,
  `latency_ms`, `rewrite` stats). That log is the dataset Phase 1+ watermark
  tuning is built on.
- Adds an `x-proxy-request-id` response header that matches the JSONL row.

Phase 0 (instrumentation), Phase 1 (Tier-1 tool-result elision +
`expand_tool_result` phantom tool), and Phase 2 (small-model recursive
summarization, off by default — set `summarizer.url`) are implemented. Phase 3
(KV stable-prefix cooperation) is **instrumented** (slot save/restore endpoints
stubbed; session keying live behind `session.enabled`). Phase 4 (Tier-2/3
structured notes — heuristic entity/kv/decision extraction) and Phase 5
(Tier-4 sumy-style extractive fallback, implemented in JS) are implemented and
**off by default** — flip `notes.enabled` and/or `sumy.enabled` in
`config.yaml` to opt in. Both run between Phase 2 and Tier 1 and only fire
when the watermark trips.

## When to use it

- You want to see, on real session traffic, where context budget is being spent
  before turning on any rewriting.
- You want Phase 1 tool-result elision to fire on long agentic sessions without
  modifying the harness (Continue, OpenCode, Zed, Aider, etc.).
- You want a single observation point that records prompt/completion tokens per
  request across every client, regardless of which one is talking.

If you just want chat, skip the proxy and point your client straight at `:10501`.

## Run it

```bash
cd proxy
npm install              # one-time
npm start                # foreground; listens on :11500
```

Or via the top-level Makefile:

```bash
make proxy-install
make proxy-start         # foreground
make proxy-smoke         # best-effort end-to-end check
```

Point the client at `http://127.0.0.1:11500` instead of `:10501`. Everything
else (model names, request shape, streaming) is unchanged.

## Modes

Set in `proxy/config.yaml` or via `QWEN_COMPACT_MODE`:

| Mode          | Behavior                                                         |
| ------------- | ---------------------------------------------------------------- |
| `passthrough` | Never rewrite. Log only. Default.                                |
| `shadow`      | Compute the would-be rewrite, log it, forward the **original**.  |
| `enforce`     | Compute the rewrite and forward the **rewritten** body upstream. |

`shadow` is the safe way to validate Phase 1 elision against your real traffic
before flipping to `enforce`.

## Bypass header

Send `x-compact: off` on any request to skip all rewriting in any mode. The flag
is recorded in the JSONL row so you can split before/after metrics later.

## Ports and config

| Setting                       | Default                       | Env override                |
| ----------------------------- | ----------------------------- | --------------------------- |
| listen host                   | `127.0.0.1`                   | —                           |
| listen port                   | `11500`                       | `QWEN_COMPACT_PORT`         |
| upstream base URL             | `http://127.0.0.1:10501`      | `QWEN_COMPACT_UPSTREAM`     |
| mode                          | `passthrough`                 | `QWEN_COMPACT_MODE`         |
| config file                   | `proxy/config.yaml`           | `QWEN_COMPACT_CONFIG`       |
| summarizer URL (Phase 2)      | _empty_ (off)                 | `QWEN_COMPACT_SUMMARIZER_URL` |

## Where artifacts persist

- **JSONL request logs:** `~/.cache/qwen-compact/logs/YYYY-MM-DD.jsonl`. One row
  per request: `request_id`, `model`, `mode`, `compact`, `stream`,
  `message_count`, `prompt_tokens`, `completion_tokens`, `status`, `latency_ms`.
- **Process stdout:** pino-formatted; redirect with `npm start > proxy.log 2>&1`
  if you want it on disk.
- **Tokenizer LRU:** in-memory only, sized via `tokenizer.cache_entries`.

The cache directory lives outside the repo on purpose — replay fixtures and
captured traffic should not land in git.

## Endpoints

| Route                          | Behavior                                           |
| ------------------------------ | -------------------------------------------------- |
| `POST /v1/chat/completions`    | Passthrough or rewrite per mode; SSE preserved.    |
| `GET /v1/models`               | Passthrough.                                       |
| `GET /health`                  | Passthrough.                                       |
| `GET /proxy/info`              | Proxy state: mode, upstream, `n_ctx`, watermarks.  |
| anything else                  | Forwarded to upstream verbatim.                    |

## Smoke check

`make proxy-smoke` brings up `llama-server` (if it isn't already), starts the
proxy in the background, regenerates the 50-turn needle fixture, runs a basic
`/v1/chat/completions` round-trip through `:11500`, and prints the matching
JSONL row. It tears down only what it started — if a server was already on
`:10501`, it's left alone.

Prerequisites: Node 18+, Python 3, and `make build` already complete.

## Verifying it end-to-end

With both servers up:

```bash
# unit (no servers needed)
cd proxy && npm test                       # 86 tests

# integration (needs llama-server :10501 + proxy :11500)
bash proxy/tests/integration.sh
```

The integration script exercises: `/v1/models`, `/proxy/info`, non-streaming
chat, SSE streaming, **non-streaming tool calls**, **tool-result round-trip**,
the `x-debug-rewritten: 1` short-circuit (returns `{}` plus an
`x-rewrite-stats` header without touching upstream), and the `x-compact: off`
bypass.

For a quick manual tool-calling probe through the proxy:

```bash
curl -s http://127.0.0.1:11500/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model":"local",
    "messages":[{"role":"user","content":"Use get_weather to check Paris."}],
    "tools":[{"type":"function","function":{"name":"get_weather",
      "parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}],
    "max_tokens":150,
    "chat_template_kwargs":{"enable_thinking":false}
  }' | jq '.choices[0].message.tool_calls'
```

To inspect what Tier-1 elision *would* do without forwarding (works in any
mode): add `-H 'x-debug-rewritten: 1'`. The proxy returns `200 {}` plus an
`x-rewrite-stats` header (`{"orig_tokens":N,"rewritten_tokens":M,"elided_tool_result_ids":[...]}`)
and either an inline `x-rewritten-messages` header (when small) or an
`x-rewritten-sidecar` path pointing at `~/.cache/qwen-compact/debug/<id>.json`.

## See also

- [`compaction-strategy.md`](compaction-strategy.md) — full design (§9 phased plan).
- [`../proxy/README.md`](../proxy/README.md) — config keys and JSONL schema.
- [`../proxy/eval/README.md`](../proxy/eval/README.md) — replay + needle harness.
