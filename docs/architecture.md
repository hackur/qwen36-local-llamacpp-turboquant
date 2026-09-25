# Architecture

The project has one model process and one optional lightweight proxy:

```text
clients ──────────────────────────────> TurboQuant llama-server :10501
   └─> optional compaction proxy :11500 ────────────────┘

TurboQuant llama-server loads Qwen3.8 Q8_0 + BF16 projector:
  - q8_0 K / turbo3 V
  - adaptive chained MTP
  - text + vision
  - preserved reasoning
  - native WebUI + agent tools + MCP
  - metrics
```

The optional proxy is a separate process and defaults to passthrough.

`configs/runtime.env` owns runtime defaults. `scripts/_common.sh` converts them
to one command array and validates every nonstandard flag against the selected
binary's `--help` output before launch. `scripts/start-turboquant.sh` adds the
TurboQuant cache and MTP flags. `scripts/start-baseline.sh` uses the same model,
projector, feature flags, and sampling through mainline llama.cpp while removing
MTP and using f16 KV.

The q8_0/turbo3 split is explicit. TurboQuant's 6:1 GQA safety logic would make
the same K-cache rewrite automatically, but explicit configuration keeps logs
and benchmark labels honest.

The default `--agent` flag is upstream shorthand for the WebUI MCP proxy plus
all built-in tools. `--cors-origins localhost` and `--host 127.0.0.1` are also
explicit. `AGENT=0 MCP_CONFIG=` removes agent tools, the WebUI MCP proxy,
and configured external stdio MCP tools without changing model behavior.

The Node proxy is a separate HTTP hop: only clients targeting `:11500` use it.
It forwards to `:10501`, preserves tool calls, and rewrites chat history only
in `enforce` mode. Its optional summarizer, notes, session state, and hooks are
disabled in the checked-in config. The optional JEV classifier call in
`proxy/src/rewrite.js` requires `jev.local_url` and a running compatible
service. The project does not launch Laya. `proxy/scripts/research.mjs` is a
standalone research script, not an automatically available model tool.
