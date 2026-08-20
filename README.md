# Qwen3.8 Local TurboQuant

**Qwen3.8-27B Q8_0** running fully offline on Apple Silicon with **TurboQuant** KV-cache compression, embedded **MTP speculative decoding**, native **262K context**, and vision. Qwen3.6 and the other installed models remain selectable fallbacks; Qwen3.8 is the single primary path.

## Why use this instead of LM Studio

LM Studio is great for downloading models. It is **not** designed to keep working when you disconnect: it caches an account check (`lm-link-account-status-cache.json`) that re-validates online, and the hub catalog refreshes on every launch. Disconnect Wi-Fi → UI hangs or blocks features.

This stack is `llama.cpp`'s `llama-server` binary directly. No Electron, no telemetry, no account, no catalog. Verified on this M3 Max with `lsof`:

```
$ lsof -nP -p $(pgrep -f vendor/llama-cpp-turboquant.*llama-server) | grep TCP
llama-ser ... TCP 127.0.0.1:10501 (LISTEN)
```

One socket. Localhost. No outbound. **Wi-Fi off → no impact.**

See [`docs/offline-mode.md`](docs/offline-mode.md) for the full offline recipe.

## Since v0.0.2

- **Interactive A/B bench TUI** — `make bench-tui` (Textual) + `make bench-suite` (headless). Suites in `benchmarks/suites/*.yaml`, append-only `events.jsonl`, one-server-at-a-time lockfile. See `docs/benchmarking-discipline.md`.
- **MCP integration in the llama.cpp WebUI** — `make mcp-fs / mcp-git / mcp-time` bridges (supergateway over stdio MCP servers), opt-in via `MCP_PROXY=1`. Default off; turning it on intentionally breaks the offline guarantee. See `docs/mcp-integration.md`.
- **Single-server thermal guard** — every `start-*.sh` refuses to launch if another `llama-server` is already running. Override with `ALLOW_STACK=1` on a cool chassis. See `docs/troubleshooting.md`.

Full history in [`CHANGELOG.md`](CHANGELOG.md).

## Current verified stack — M3 Max 64 GB

| Component | Verified revision/version |
|---|---|
| Qwen | Qwen3.8-27B Q8_0 + BF16 projector |
| TurboQuant | `bd1bf025f` (2026-08-19) |
| llama.cpp | `681c29d36` (2026-08-20) |
| Node proxy deps | js-yaml 5.3.0, pino 10.3.1 |
| Native context | 262,144 tokens |

Measured on this machine: **3.85 s warm load**, **24.60 tok/s** with embedded MTP at 32K, and **5.14 s** warm load at the full 262K context. TurboQuant automatically rewrites Qwen3.8's requested `turbo3/turbo3` cache to the quality-safe effective `q8_0/turbo3` split for its 24:4 GQA ratio. MTP is the main generation-speed win; set `MTP=0` only for comparison or troubleshooting.

Long-context recall: needle at 50K tokens **recovered exactly**. Server log confirms TurboQuant Metal kernels are live: `ggml_metal_library_init: turbo3 using 4-mag LUT (pre-M5 hardware)`.

Full results: [`benchmarks/RESULTS.md`](benchmarks/RESULTS.md).

## Quickstart

Requirements: macOS on Apple Silicon, Xcode command line tools, Git, CMake, curl, jq, Python 3, and enough disk for the selected GGUF model plus two `llama.cpp` checkouts.

Optional Python deps (only for `make bench-tui` / `make bench-suite`):

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements-tui.txt
```

Homebrew Python is PEP-668 externally-managed, so a venv is required;
the directory is gitignored. Optional Node deps for `make mcp-*`:
`brew install node` (npx pulls supergateway on first run).

```bash
make preflight                # checks tools, builds, and model symlinks
make build                    # one-time, ~5 min, Metal builds of both forks
make start                    # Qwen3.8 + TurboQuant + MTP on :10501
make open                     # opens clients/web-demo.html in your browser
```

Or double-click **`Qwen-Offline.command`** in Finder — starts the server and pops the web UI.

## What can you do with this?

| Goal | Recipe | Pointer |
|---|---|---|
| Chat in a browser | `make start && make open` | `clients/web-demo.html` |
| Chat in terminal | `make start && make demo` | [`docs/demo-chat.md`](docs/demo-chat.md) |
| Use it with VS Code Continue | drop `configs/continue.json` | [`docs/usage.md`](docs/usage.md#editor-integration) |
| Long-context document QA | native 262K context with `qwen38-27b` | [`docs/usage.md`](docs/usage.md#long-context-document-qa--rag) |
| Ask about an image | `make start-vision` | [`docs/multimodal.md`](docs/multimodal.md) |
| Strict JSON output | `response_format: {"type":"json_schema", ...}` | [`docs/usage.md`](docs/usage.md#json--structured-output) |
| Switch model on the fly | `make stop && make start-gemma4-26b` | [`docs/usage.md`](docs/usage.md#switching-models-live-stop-and-swap) |
| Tiny Qwen-family model / speculative-decoding draft | `qwen3.5-0.8b` alias (~775 MB Q8_0, shared tokenizer with Qwen3.5/3.6) | [`docs/speculative-decoding.md`](docs/speculative-decoding.md) |
| Streaming tokens (curl/python/JS) | three working examples | [`docs/usage.md`](docs/usage.md#streaming-chat--three-languages) |
| Context compaction for long agentic sessions | transparent proxy on `:11500` in front of `:10501` (tool calling + SSE preserved) | [`docs/proxy.md`](docs/proxy.md) |
| Run an A/B bench suite | `make bench-suite SUITE=…` | [`docs/benchmarking-discipline.md`](docs/benchmarking-discipline.md) |
| Interactive bench TUI | `make bench-tui SUITE=…` | [`docs/benchmarking-discipline.md`](docs/benchmarking-discipline.md) |
| MCP tool use in WebUI | `MCP_PROXY=1 make start ; make mcp-fs` | [`docs/mcp-integration.md`](docs/mcp-integration.md) |
| See live status / memory / network | `make info` or `make info-watch` | scripts/info.sh |
| Confirm offline-clean | `make audit-offline` | scripts/info.sh |

**The full cookbook with examples for every model is [`docs/usage.md`](docs/usage.md).**

To make it auto-start at login (truly always-on offline):

```bash
make install-launchd
```

## What's running right now

```bash
make info        # one screen: env, server config, params, KV type, RSS,
                 # system memory, inbound/outbound sockets, disk usage,
                 # launchd state, last bench numbers
make info-watch  # same, refreshing every 2 s
```

The web demo also has an **info drawer** in the header (collapsed by default) with:
- active server (model, params, context loaded/trained, build SHA)
- this session (messages, user/assistant token estimates, last gen rate)
- live activity from `/slots` (idle / generating)
- sampling defaults from `/props`

## All targets

Run `make help` for the full annotated list (kept in sync with the Makefile).

## Hardware tested

Apple M3 Max · 64 GB unified memory · macOS 26.4.1.

## Minimum requirements

- **Apple Silicon Mac** (M1/M2/M3/M4). x86_64 macs and Linux/Windows are out of scope — the build uses the Metal backend.
- **macOS 14+** (tested on 26.4).
- **Xcode Command Line Tools** (`xcode-select --install`) for the C++ compile.
- **`brew install cmake jq`** — both used by the scripts.
- **Free RAM** — at least 8 GB for `tiny`, 16 GB for `nemotron-4b`/`gemma4-e4b`/`crow-9b`, and 32 GB for the small/medium fallbacks. **64 GB is recommended for the default Qwen3.8 Q8 path**; full 262K measured at roughly 34.5 GiB RSS.
- **Free disk** — about 1.5 GB for builds; models live in your existing LM Studio cache (or wherever `MODELS_ROOT=` points).
- **No models in this repo** — see [`docs/install-models.md`](docs/install-models.md) for downloading GGUFs without LM Studio.

Run `make preflight` to check all prerequisites at once. Run `make check` to lint scripts and scan for accidental personal paths.

## License & contributing

[`LICENSE`](LICENSE) is MIT — model weights and upstream `llama.cpp` retain their own licenses (linked from the LICENSE file). [`SECURITY.md`](SECURITY.md) covers the threat model and how to report issues. [`CONTRIBUTING.md`](CONTRIBUTING.md) has the pre-PR checklist.

## Layout

```
README.md             this file
PLAN.md               original 41-task implementation plan
Makefile              ergonomic wrappers
Qwen-Offline.command  double-click launcher (Finder)
scripts/              build, start-*, stop-all, status, bench, needle, demo, healthcheck, symlink,
                      sustained-load runbooks (sweep-ctx-batch, ablate-sparse-v, test-np-concurrency,
                      test-spec-decode, bench-summarizer), compare-lmstudio (TurboQuant vs LM Studio),
                      quarterly-audit, analyze-watermarks, synthesize-telemetry, diagnose-variance,
                      start-embed
clients/              python-demo.py · web-demo.html
configs/              opencode, continue, launchd plist, launchd-quarterly.template (Jan/Apr/Jul/Oct
                      LM Studio re-audit), sampling, model-defaults.env (per-alias CTX/KV/RoPE)
proxy/                compaction reverse proxy on :11500 — tier-1 elision, summarizer hook,
                      session keying, structured notes, hooks-middleware engine — see docs/proxy.md
docs/                 architecture, offline-mode, multimodal, troubleshooting, references,
                      proxy, hooks-middleware, speculative-decoding, upstream-tracking,
                      watermark-tuning, …
benchmarks/           RESULTS.md + raw run logs
vendor/               llama.cpp-mainline + llama-cpp-turboquant (gitignored)
models/               symlinks to LM Studio GGUFs
logs/                 runtime logs (gitignored)
```

## Further reading

- [`docs/proxy.md`](docs/proxy.md) — compaction reverse proxy operator guide.
- [`docs/hooks-middleware.md`](docs/hooks-middleware.md) — v0.2 spec + §11 battle-test results.
- [`docs/speculative-decoding.md`](docs/speculative-decoding.md) — when it helps, draft acquisition, tokenizer-mismatch pitfall.
- [`docs/upstream-tracking.md`](docs/upstream-tracking.md) — pinned TurboQuant + mainline SHAs and quarterly recheck recipe.
- [`docs/api.md`](docs/api.md) — embeddings server (`:10510`) and the rest of the HTTP surface.

You can skip LM Studio if you already have GGUFs somewhere else:

```bash
MODEL=/path/to/model.gguf ./scripts/start-turboquant.sh
MODEL=/path/to/model.gguf MMPROJ=/path/to/mmproj.gguf ./scripts/start-vision.sh
```

## Optional: weekly health check

If you want a recurring background agent to confirm nothing has regressed, you can use Claude Code's `/schedule` to run something like:

```
make audit-offline && make bench && make needle
```

…on a weekly cadence. Skip it unless you actually want the routine — the stack works without it.

## What this isn't

A model trainer, a fine-tuning toolkit, a MCP server, or a Cursor replacement. It's a **local inference server** with one job: serve Qwen3.8 reliably with the network off, fast, on Apple Silicon.
