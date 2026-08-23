# Qwen3.8 Local TurboQuant

One model, one endpoint, one supported configuration: **Qwen3.8-27B Q8_0**
on Apple Silicon through the active TurboQuant llama.cpp fork.

The default runtime on `http://127.0.0.1:10501` enables:

- native 262,144-token context;
- explicit q8_0 K / turbo3 V cache for Qwen3.8's 6:1 GQA layout;
- adaptive, chained embedded-MTP decoding (depth 3–8);
- the matching BF16 vision projector;
- Qwen3.8 thinking mode and preserved reasoning history;
- llama.cpp metrics, native WebUI, MCP proxy, and all built-in agent tools.

No fallback models, draft sidecars, embedding models, custom chat templates,
or legacy model aliases are supported. Historical implementations remain in
git history, not in the working tree.

## Quick start

```bash
brew install cmake jq
make model-link       # links existing LM Studio Qwen3.8 artifacts
make build            # builds the pinned Metal engines
make preflight        # checks artifacts and every required server flag
make start            # background full runtime
make open             # native llama.cpp WebUI
```

Finder users can double-click `Qwen3.8.command`.

The expected local artifacts are:

- `lmstudio-community/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q8_0.gguf`
- `lmstudio-community/Qwen3.8-27B-GGUF/mmproj-Qwen3.8-27B-BF16.gguf`

Set `MODELS_ROOT=/path/to/ggufs` when they are not under LM Studio's default
cache. See [install-models](docs/install-models.md).

## Security profile

`make start` deliberately uses llama.cpp `--agent`, which enables its WebUI MCP
proxy and built-in read, search, shell, write, edit, time, and info tools. The
server binds only to `127.0.0.1` and restricts CORS to localhost, but tool use
still grants the model local-machine capabilities. Do not expose this port.

Use `make start-offline` to keep MTP, vision, reasoning, and metrics while
disabling agent tools and the MCP proxy. See [SECURITY.md](SECURITY.md).

## Runtime controls

Defaults live in [`configs/runtime.env`](configs/runtime.env). Environment
overrides are intentionally temporary:

```bash
MTP=0 make start-foreground                 # same model, no speculative decode
CTX=131072 make start-foreground            # smaller memory footprint
AGENT=0 make start-foreground               # strict local inference profile
MCP_CONFIG=/abs/path/mcp.json make start-foreground
```

`make start-baseline` runs the same weights and projector through mainline
llama.cpp with f16 KV and no MTP. It exists only as a controlled comparison.

## Local validation

```bash
make check            # shell/Python syntax + unit tests + privacy scan
make proxy-test       # compaction proxy tests
make quality          # deterministic text checks against a running model
make eval             # ten-case pass/fail model acceptance gate
make vision           # multimodal request against the same :10501 server
make needle           # 50K long-context recall probe
make bench            # current endpoint throughput
make bench-tui        # queued A/B feature suite
```

There are intentionally no hosted CI workflows. Validation is local because
the meaningful tests require this Mac, these GGUFs, Metal, and a cool chassis.

## Documentation

- [Architecture and feature flags](docs/architecture.md)
- [Usage and API examples](docs/usage.md)
- [Vision](docs/multimodal.md)
- [MTP](docs/speculative-decoding.md)
- [Agent tools and MCP](docs/mcp-integration.md)
- [Benchmarking](docs/benchmarking-discipline.md)
- [Compaction proxy](docs/proxy.md)
- [Upstream pins and research](docs/upstream-tracking.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Primary sources](docs/references.md)

## Hardware

Verified on an Apple M3 Max with 64 GiB unified memory. Full native context
needs roughly 35 GiB of process RSS with the current Q8_0 weights, projector,
KV cache, and MTP context. The server is localhost-only and macOS/Metal-tuned.
