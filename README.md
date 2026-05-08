# qwen36-local-llamacpp-turboquant

**Qwen 3.6** running fully offline on Apple Silicon, with **TurboQuant** KV-cache compression for 2× context at the same speed. Built around the YouTube guide [_Ultimate Guide Local AI Setup (Qwen3.6 + LlamaC++ + TurboQuant)_](https://www.youtube.com/watch?v=5jkAlqbk66A).

## Why use this instead of LM Studio

LM Studio is great for downloading models. It is **not** designed to keep working when you disconnect: it caches an account check (`lm-link-account-status-cache.json`) that re-validates online, and the hub catalog refreshes on every launch. Disconnect Wi-Fi → UI hangs or blocks features.

This stack is `llama.cpp`'s `llama-server` binary directly. No Electron, no telemetry, no account, no catalog. Verified on this M3 Max with `lsof`:

```
$ lsof -nP -p $(pgrep -f vendor/llama-cpp-turboquant.*llama-server) | grep TCP
llama-ser ... TCP 127.0.0.1:10501 (LISTEN)
```

One socket. Localhost. No outbound. **Wi-Fi off → no impact.**

See [`docs/offline-mode.md`](docs/offline-mode.md) for the full offline recipe.

## What's new in v0.0.2

- **Compaction reverse proxy** at `proxy/` (`:11500` → `:10501`) shipped through Phases 2–5: Tier-1 elision, recursive summarizer hook, session keying, structured notes + sumy fallback. See [`docs/proxy.md`](docs/proxy.md).
- **Hooks-middleware v0.2 spec ratified** + MVP engine with 5 built-in handlers wired at four request phases (zero per-request cost when `hooks:` absent). See [`docs/hooks-middleware.md`](docs/hooks-middleware.md) §11.
- **A/B battle-test results populated** — 5 fixtures, 30 cells, 0 errors, 100% needle + decision preservation, tier0+tier1 −49.9% on tool-heavy fixtures.
- **Sustained-load runbook scripts** — `scripts/{sweep-ctx-batch,ablate-sparse-v,test-np-concurrency,test-spec-decode,bench-summarizer}.sh`, all collision-safe against the launchd primary.
- **`qwen3.5-0.8b` draft alias** (~775 MB Q8_0) — standalone tiny target plus speculative-decoding draft for the Qwen3.5/3.6 family. See [`docs/speculative-decoding.md`](docs/speculative-decoding.md).
- **Embeddings server scaffold** — `scripts/start-embed.sh` on `:10510` (KV f16, `--embedding`). See [`docs/api.md`](docs/api.md).
- **Upstream tracking** — `docs/upstream-tracking.md` pins TurboQuant + mainline SHAs and q8_0 model pins, with a quarterly recheck recipe.
- **Quarterly LM Studio re-validation** — `scripts/quarterly-audit.sh` + `configs/launchd-quarterly.template` (Jan/Apr/Jul/Oct).
- **Mixed K/V guard rail** (`apply_kv_split`, sentinel `mixed-kv-guard:v1`) and **opt-in `/metrics`** (`METRICS=1`, default off so generation counts don't leak to localhost).
- **KV-cache math corrected by 4×** across `docs/{kv-cache-math,architecture,context-matrix}.md`; default model swapped to `qwen36-neo` (256K native, uncensored, code-tuned), `qwen36-35b` preserved as `MODEL_FALLBACK`.
- **Summarizer bench run** — `nemotron-4b` recommended for the Phase 2 slot (near-tie with gemma4-e4b on quality, ~3× smaller VRAM). Recorded in `proxy/config.yaml` and `docs/compaction-strategy.md` §11.
- **100K-needle long-context recall** — `qwen36-neo` turbo3 @131K recovered the password from a 72 546-token prompt at depth 50% (exact match). Smaller probes at 5K and 30K also recovered. See `benchmarks/RESULTS.md`.
- **`scripts/bench-summarizer.sh` teardown fix** — the wrapper's `exec | tee` chain reparented `llama-server` away from `$!`, leaking transient servers and pushing the system to swap-fill. Now resolves the real PID via `lsof`.
- **Watermark analyzer demo + interpretation guide** — `scripts/synthesize-telemetry.py` fabricates plausible JSONL so `scripts/analyze-watermarks.py` can be exercised end-to-end without a week of shadow-mode traffic. See [`docs/watermark-tuning.md`](docs/watermark-tuning.md).
- **TurboQuant vs LM Studio runbook** — `scripts/compare-lmstudio.sh` walks through stopping the primary, booting LM Studio's runtime against the same GGUF, capturing tok/s, and restoring.

Full details in [`CHANGELOG.md`](CHANGELOG.md).

## Real numbers — Qwen3.6-27B-Heretic-NEO-CODE Q5_K_M on M3 Max 64GB

| Profile | KV cache | Context | Gen tok/s | Prompt tok/s | Notes |
|---|---|---|---|---|---|
| **turboquant** | **turbo3** | **128K** | **14** | ~78 | 20.4 GB VRAM, dense uncensored finetune |
| **turboquant** | **turbo3** | **256K** | **7** | ~53 | 22.7 GB VRAM, native `n_ctx_train` |

KV @ turbo3 measures **15.2 KiB/tok** (vs ~64 KiB/tok at f16 on this same model). Hybrid Qwen3.6 architecture: only 16 of 64 layers carry KV (attn + Gated Delta Net). Slower than the prior 35B-A3B MoE (63 / 322 tok/s @ 64K) but uncensored, code-tuned, and runs at 4× the context. The 35B-A3B remains as `MODEL_FALLBACK`.

Long-context recall: needle at 50K tokens **recovered exactly**. Server log confirms TurboQuant Metal kernels are live: `ggml_metal_library_init: turbo3 using 4-mag LUT (pre-M5 hardware)`.

Full results: [`benchmarks/RESULTS.md`](benchmarks/RESULTS.md).

## Quickstart

Requirements: macOS on Apple Silicon, Xcode command line tools, Git, CMake, curl, jq, Python 3, and enough disk for the selected GGUF model plus two `llama.cpp` checkouts.

```bash
make preflight                # checks tools, builds, and model symlinks
make build                    # one-time, ~5 min, Metal builds of both forks
make start                    # turboquant server on :10501 (default model: qwen36-neo)
make open                     # opens clients/web-demo.html in your browser
```

Or double-click **`Qwen-Offline.command`** in Finder — starts the server and pops the web UI.

## What can you do with this?

| Goal | Recipe | Pointer |
|---|---|---|
| Chat in a browser | `make start && make open` | `clients/web-demo.html` |
| Chat in terminal | `make start && make demo` | [`docs/demo-chat.md`](docs/demo-chat.md) |
| Use it with VS Code Continue | drop `configs/continue.json` | [`docs/usage.md`](docs/usage.md#editor-integration) |
| Long-context document QA | up to 256K tokens of context with `qwen36-neo` | [`docs/usage.md`](docs/usage.md#long-context-document-qa--rag) |
| Ask about an image | `make stop && MODEL=qwen36-neo PORT=10503 ./scripts/start-vision.sh &` | [`docs/multimodal.md`](docs/multimodal.md) |
| Strict JSON output | `response_format: {"type":"json_schema", ...}` | [`docs/usage.md`](docs/usage.md#json--structured-output) |
| Switch model on the fly | `make stop && make start-gemma4-26b` | [`docs/usage.md`](docs/usage.md#switching-models-live-stop-and-swap) |
| Tiny Qwen-family model / speculative-decoding draft | `qwen3.5-0.8b` alias (~775 MB Q8_0, shared tokenizer with Qwen3.5/3.6) | [`docs/speculative-decoding.md`](docs/speculative-decoding.md) |
| Streaming tokens (curl/python/JS) | three working examples | [`docs/usage.md`](docs/usage.md#streaming-chat--three-languages) |
| Context compaction for long agentic sessions | transparent proxy on `:11500` in front of `:10501` (tool calling + SSE preserved) | [`docs/proxy.md`](docs/proxy.md) |
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

```
$ make
Targets:
  build               Build mainline + TurboQuant llama.cpp (Metal). Idempotent.
  start               Start default model (qwen36-neo) on :10501
  start-baseline      Start mainline f16 baseline (port 10500)
  start-tiny          TinyLlama 1.1B (smoke test) — uses q8_0
  start-nemotron      Nemotron-3 4B
  start-crow          Crow 9B (Qwen3.5 distill)
  start-gemma4-e4b    Gemma 4 E4B
  start-qwen35-9b     Qwen 3.5 9B
  start-gpt-oss       GPT-OSS 20B — uses q8_0
  start-gemma4-26b    Gemma 4 26B-A4B (MoE)
  start-qwen36-27b    Qwen 3.6 27B
  start-qwen36-neo    Qwen 3.6 27B Heretic-Uncensored NEO-CODE (default)
  preflight           Check tools, builds, and model symlinks without starting a server
  check               Run static checks that do not need models or network
  models              List every available model alias
  stop                Stop all llama-server processes from this repo
  status              What's running and where (terse)
  info                Full one-shot dashboard (env, server, memory, network, disk, launchd, last bench)
  info-watch          Same as `info`, refreshing every 2 s
  bench               Run A/B benchmark (assumes both servers up)
  needle              Long-context recall test on TurboQuant
  demo                Terminal chat REPL
  open                Open the web demo in your browser
  install-launchd     Install launchd auto-start (always-on offline)
  uninstall-launchd   Remove launchd auto-start
  clean               Wipe build artifacts (does NOT delete vendor/ source)
  audit-offline       Confirm llama-server has zero non-localhost sockets
  proxy-install       Install compaction proxy npm dependencies
  proxy-test          Run compaction proxy unit + stub-upstream tests
  proxy-start         Start compaction proxy on :11500 (foreground)
  proxy-smoke         Best-effort end-to-end smoke (server + proxy + needle + curl)
```

## Hardware tested

Apple M3 Max · 64 GB unified memory · macOS 26.4.1.

## Minimum requirements

- **Apple Silicon Mac** (M1/M2/M3/M4). x86_64 macs and Linux/Windows are out of scope — the build uses the Metal backend.
- **macOS 14+** (tested on 26.4).
- **Xcode Command Line Tools** (`xcode-select --install`) for the C++ compile.
- **`brew install cmake jq`** — both used by the scripts.
- **Free RAM** — at least 8 GB for `tiny`, 16 GB for `nemotron-4b`/`gemma4-e4b`/`crow-9b`, 32 GB for `qwen35-9b`/`gpt-oss-20b`/`qwen36-27b`/`gemma4-26b`, **64 GB recommended for the default `qwen36-neo` (~22 GB VRAM @ 256K) and the `qwen36-35b` fallback**.
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

A model trainer, a fine-tuning toolkit, a MCP server, or a Cursor replacement. It's a **local inference server** with one job: serve Qwen 3.6 reliably with the network off, fast, on Apple Silicon.
