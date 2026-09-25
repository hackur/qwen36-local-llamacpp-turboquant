# Usage

## Native WebUI

```bash
make start
make open
```

The WebUI provides thinking controls, image attachments, built-in agent tools,
MCP server management, and conversation history. It is the supported browser
client because it tracks the server's features directly.

`make start` starts only the model server on `:10501`. Its default `AGENT=1`
enables the WebUI MCP CORS proxy and all eight built-in tools. The model chooses
tools as needed during agent sessions; enabling them does not run them on every
request. External MCP tools require `MCP_CONFIG`. Check the active set with:

```bash
curl -s http://127.0.0.1:10501/tools | jq -r '.[].tool'
```

The independent context-compaction proxy starts with `make proxy-start` and
listens on `:11500`. Clients must explicitly use that URL to pass through it.
Its checked-in mode is `passthrough`; see [proxy](proxy.md) for `shadow` and
`enforce` and the optional JEV/Laya classifier gate. `make status` shows the
model and proxy listeners, plus the proxy mode and JEV gate when running.
`make start-offline` removes llama.cpp agent tools and its WebUI MCP proxy; it
does not start or stop the Node proxy.

## OpenAI-compatible text request

```bash
curl http://127.0.0.1:10501/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model":"qwen3.8-local",
    "messages":[{"role":"user","content":"Explain the current runtime."}],
    "max_tokens":1024
  }'
```

Qwen3.8 thinks by default. The server uses Qwen's official thinking sampling:
temperature 1.0, top-p 0.95, top-k 20, min-p 0.0, presence penalty 0.0.

For direct non-thinking output, use Qwen's official instruct sampling:

```json
{
  "temperature": 0.7,
  "top_p": 0.8,
  "top_k": 20,
  "min_p": 0.0,
  "presence_penalty": 1.5,
  "reasoning_effort": "none",
  "chat_template_kwargs": {"enable_thinking": false}
}
```

Preserved reasoning is enabled at the server. Disable it per request with
`chat_template_kwargs.preserve_thinking=false` when the client must not retain
historical thought blocks.

## Editor clients

`configs/continue.json` and `configs/opencode.json` both point to
`qwen3.8-local` on `:10501`. Their 262,144-token setting is a client
configuration, not proof of the active server context. Check `GET /props`
after launching with an override such as `CTX=98304`:

```bash
curl -s http://127.0.0.1:10501/props | jq '.default_generation_settings.n_ctx'
```

## Strict offline profile

```bash
make start-offline
```

This disables agent tools and the WebUI MCP proxy. MTP, vision, reasoning,
metrics, and the OpenAI-compatible API remain enabled.
