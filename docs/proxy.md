# Compaction proxy

The optional Node proxy listens on `:11500` and forwards to the Qwen3.8
runtime on `:10501`. Start it separately, then point a client at `:11500`.
`make start` and the checked-in editor configs use `:10501` directly. This
Node proxy is distinct from llama.cpp's WebUI MCP CORS proxy enabled by
`--agent`. It preserves OpenAI-compatible streaming and tool calls.

```bash
make proxy-install
make proxy-test
make proxy-start
```

In another terminal, send a request through the proxy explicitly:

```bash
curl http://127.0.0.1:11500/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"qwen3.8-local","messages":[{"role":"user","content":"Hello"}]}'
```

Configuration is in `proxy/config.yaml`. Main modes are `passthrough`,
`shadow`, and `enforce`. The checked-in default is `passthrough`, so no
compaction is applied. `shadow` computes and logs a rewrite while forwarding
the original; `enforce` forwards the rewrite. `x-compact: off` bypasses
rewriting per request. `GET /proxy/info` reports the running configuration.
`make status` shows whether the proxy is up, its mode, and whether its JEV
classifier gate is enabled.

The proxy supports:

- verbatim-window selection;
- oversized tool-result elision and local rehydration;
- optional same-model summarization through Qwen3.8 on `:10501`;
- structured-note and extractive fallbacks;
- session keys and TTL state;
- request-phase hooks;
- JSONL telemetry and watermark analysis.

The checked-in summarizer, structured notes, session state, hooks, and JEV
classifier gate are disabled. Set `jev.local_url` to a running Laya-compatible
`/v1/systemone` service to enable classification during a rewrite. In
`local-first` mode, a failed local call can fall back to TypeSafe cloud only
when its API key is available. The response includes route, thinking, and risk
signals; the current rewrite path uses only `route=compact` with confidence
at least 0.6 to keep fewer recent turns and lower the tool-result elision
threshold. If classification fails, ordinary thresholds apply. `passthrough`
does not run the rewrite or its classifier; `shadow` measures a candidate but
forwards the original; only `enforce` forwards the compacted request.

`proxy/scripts/research.mjs` is a separate, manually run research command. It
uses JEV to rerank retrieved pages and the direct Qwen3.8 server to synthesize
an answer. It can make outbound search, page-fetch, and classifier requests.
It is not registered as a llama.cpp or MCP tool. The JEV/Laya demo script
starts temporary fake classifier servers; it does not start Laya itself.

There is no summarizer sidecar. When enabled, the proxy calls the direct
Qwen3.8 upstream before forwarding the rewritten main request, avoiding
recursive proxy traffic and another model in memory.

Run `make proxy-test` for the Node suite. Run `make proxy-smoke` only while the
Qwen3.8 server is available.
