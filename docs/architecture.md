# Architecture

The project has one heavy process and one optional lightweight proxy:

```text
Qwen3.8 Q8_0 + BF16 projector
        |
TurboQuant llama-server :10501
  - q8_0 K / turbo3 V
  - adaptive chained MTP
  - text + vision
  - preserved reasoning
  - native WebUI + agent tools + MCP
  - metrics
        |
optional compaction proxy :11500
```

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
explicit. `AGENT=0` removes the capability without changing model behavior.
