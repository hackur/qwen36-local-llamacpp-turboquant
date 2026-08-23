# Compaction proxy

The optional Node proxy listens on `:11500` and forwards to the single Qwen3.8
runtime on `:10501`. It preserves OpenAI-compatible streaming and tool calls
while applying configurable context compaction.

```bash
make proxy-install
make proxy-test
make proxy-start
```

Configuration is in `proxy/config.yaml`. Main modes are `passthrough`,
`shadow`, and `enforce`; `x-compact: off` bypasses rewriting per request.

The proxy supports:

- verbatim-window selection;
- oversized tool-result elision and local rehydration;
- optional same-model summarization through Qwen3.8 on `:10501`;
- structured-note and extractive fallbacks;
- session keys and TTL state;
- request-phase hooks;
- JSONL telemetry and watermark analysis.

There is no summarizer sidecar. When enabled, the proxy calls the direct
Qwen3.8 upstream before forwarding the rewritten main request, avoiding
recursive proxy traffic and another model in memory.

The 129 Node tests are the authoritative proxy gate. Run the live integration
test only while the Qwen3.8 server is available.
