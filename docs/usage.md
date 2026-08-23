# Usage

## Native WebUI

```bash
make start
make open
```

The WebUI provides thinking controls, image attachments, built-in agent tools,
MCP server management, and conversation history. It is the supported browser
client because it tracks the server's features directly.

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

`configs/continue.json` and `configs/opencode.json` both point only to
`qwen3.8-local` on `:10501` with 262,144-token context.

## Strict offline profile

```bash
make start-offline
```

This disables agent tools and the WebUI MCP proxy. MTP, vision, reasoning,
metrics, and the OpenAI-compatible API remain enabled.
