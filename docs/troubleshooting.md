# Troubleshooting

## Build

### "No CMAKE_C_COMPILER could be found"
Run `xcode-select --install` and re-run `scripts/build-llama.sh`.

### Metal shader compile errors
`xcode-select -p` must point at a real Xcode (not just CLT) for Metal shader compilation. If `cmake -DGGML_METAL=ON` reports "Metal shader compiler not found":
```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

### TurboQuant fork builds but no `turbo[234]` in `--help`
```bash
vendor/llama-cpp-turboquant/build/bin/llama-server -h | grep -E 'turbo|cache.type'
```
- If empty, the wrong branch was checked out. The TurboQuant code lives on `feature/turboquant-kv-cache`, **not `master`**. The build script clones with `--branch feature/turboquant-kv-cache --depth 1`. Verify:
  ```bash
  cd vendor/llama-cpp-turboquant && git rev-parse --abbrev-ref HEAD
  ```
- If the binary exists but the flag is unknown at runtime (`Unsupported cache type: turbo3`), the TurboQuant kernels likely didn't compile for Metal — fall back to `-ctk q8_0 -ctv q8_0` via `scripts/start-fallback.sh`.

## Server won't start

### `address already in use`
LM Studio's default server is on **:1234**. We use **:10500/10501/10502** for llama-server and **:11500** for the compaction proxy. The `start-*.sh` scripts now share an `ensure_port_free` sentinel in `scripts/_common.sh` that aborts with a clear message before launch if any of those ports are squatted (commonly by LM Studio). To diagnose:
```bash
lsof -nP -iTCP:10501 -sTCP:LISTEN
```
Kill the holder or override: `PORT=10503 ./scripts/start-turboquant.sh`.

### Model file not found
Open LM Studio → Models, confirm the GGUF is downloaded. Or override:
```bash
MODEL=/some/other/path.gguf ./scripts/start-baseline.sh
```

## Runtime

### Tok/s is half what was advertised
- macOS Activity Monitor → Energy → confirm power source. Plugged-in M3 Max scores ~30% better than on-battery (measured throttle, not anecdotal).
- Other GPU work in flight (Final Cut, video calls) steals Metal time.
- Confirm `-ngl 99` (all layers on GPU). With 0, llama.cpp runs CPU-only.
- Confirm `-fa on` (flash attention) — without it, prompt-eval drops a lot.
- Confirm K and V are the **same** cache type. Mixed `-ctk turbo3 -ctv f16` (or vice versa) measured ~50% slower than matched pairs in the llama-bench cross-product (376–536 tok/s pp vs. 1015 matched). Never mix K and V types — see `HANDOFF.md` for the full table.

### Run-to-run gen tok/s varies a lot (qwen36-neo)
Generation rate has been observed at 4.75–14.49 tok/s across back-to-back 128K runs on the same machine. This is background-load sensitive — at ~22 GB VRAM resident, any other GPU consumer (Spotlight indexing, browser compositor, another model) shows up as variance. Pin a measurement run with `caffeinate -di` and close other GPU apps; otherwise treat single numbers as indicative, not authoritative.

### "Prompt too long" at 100K tokens
- Confirm the server was started with `-c 131072` (default in `start-turboquant.sh`).
- If the build ran out of memory allocating the KV cache at start, it would have logged "ggml_metal: failed to allocate buffer". Reduce `-c` or use a smaller KV type.

### Quality regression on TurboQuant vs baseline
Run `scripts/quality-check.sh` and diff outputs. turbo3 trades some bits for context — if a prompt is sensitive to recall fidelity, route it to baseline (port 10500).

## Compaction proxy (:11500)

### Client gets `ECONNREFUSED` from `:11500`
The proxy is a separate Node/Fastify process — `scripts/start-turboquant.sh` does **not** launch it. Start it explicitly: `cd proxy && npm start` (or `make proxy`). The proxy in turn forwards to llama-server on `:10501`, so both must be up.

### `completion_tokens: null` in proxy JSONL logs
**Fixed** in `b9bb6f1` (`fix(proxy): brace-balance sniffUsage so completion_tokens is logged`). The old regex `\{[^}]*\}` bailed at the first inner `}`, so any `usage` block with a nested `prompt_tokens_details` (i.e. every real llama-server response) logged `completion_tokens` as `null`. If you're on an older proxy build and seeing this, pull and restart — covered by `proxy/tests/sniff-usage.test.js`.

### Tool-call results re-expanded unexpectedly
That's Tier-1 elision doing its job: the proxy truncates large `tool` messages and offers an `expand_tool_result` phantom tool to rehydrate. If a client model calls it spuriously, raise the elision threshold or run the proxy in `passthrough` mode. See `docs/proxy.md`.

## Model-specific gotchas

### `Abort trap: 6` during model load
The `KV=turbo3` kernel doesn't support every architecture / quantization. Confirmed crashes on M3 Max:

| Model | Crashes? | Recommended KV |
|---|---|---|
| `tiny` (TinyLlama 1.1B) | yes — head dim too small | `q8_0` |
| `gpt-oss-20b` (MXFP4) | yes — kernel doesn't handle MXFP4 weights with turbo3 | `q8_0` |
| everything else we tested | no | `turbo3` |

Their per-model Make targets pin `KV=q8_0` automatically. Manually:
```bash
MODEL=tiny KV=q8_0 ./scripts/start-turboquant.sh > logs/turboquant.log 2>&1 &
```

### Empty replies from Qwen models
Qwen 3.5 / 3.6 default to `enable_thinking:true` with `--jinja`. Short `max_tokens` budgets get fully consumed by the `<think>...</think>` block. Either:
- bump `max_tokens` to 1500+ for chain-of-thought, or
- pass `chat_template_kwargs: {"enable_thinking": false}` for direct replies.

Gemma 4, GPT-OSS, and other non-Qwen models ignore the flag — they don't have a thinking mode in their chat template.

### Markdown fences around JSON
Even when told "JSON only", Qwen and Gemma wrap output in ```` ```json ```` fences for chat formatting. Solutions, in increasing strictness:
1. Strip with sed: `sed -E 's/^```(json)?//; s/```$//'`
2. Use `response_format: {"type":"json_object"}` + a system prompt
3. Use `response_format: {"type":"json_schema", ...}` — strictest, works without a system prompt

See [`docs/usage.md`](usage.md#json--structured-output).

## macOS gotchas

### `rotate-logs.sh` errors with `File: unbound variable`
You have GNU coreutils' `stat` in PATH (e.g. via `brew install coreutils` aliasing `stat` → `gstat`). GNU `stat -f` means "filesystem info"; BSD `stat -f` means "format". Already fixed in `rotate-logs.sh` (uses `wc -c`), but if you've forked and re-introduced `stat`, switch to `wc -c < file` for portability.

### `make needle` returns HTTP 400
The needle test asks for ~50K tokens. If the running server's `n_ctx` is smaller (default for `start-turboquant.sh` is 128K, but anything you've launched with `CTX=32768` etc. won't accept 50K). Either:
- restart the server: `make stop && make start`
- or lower the target: `python3 scripts/needle.py 20000`
- the test now auto-clamps to 80% of the server's loaded `n_ctx`.

### Empty replies from `healthcheck.sh` or any test prompt
Qwen 3.6 has thinking mode on by default. If `max_tokens` is small (e.g. 20), the entire budget goes to `<think>...</think>` and the visible content is empty. Already handled in our test scripts via `chat_template_kwargs:{"enable_thinking":false}`. For your own clients, either set thinking off or give the model 500+ max_tokens.

## Top-5 errors we actually hit

The first three came from the upstream iflow-mcp + Hugging Face TurboQuant guide; E4–E5 are macOS/Metal-specific things this fork has been bitten by.

| # | Symptom | Cause | Fix |
|---|---|---|---|
| E1 | `llama-server -h \| grep turbo` empty | Wrong repo (`turboquant_plus` is a Python lib) | Use `TheTom/llama-cpp-turboquant` |
| E2 | Build succeeds but inference is slow | Old cmake flag `-DLLAMA_CUBLAS=ON` silently ignored | Use `-DGGML_METAL=ON` (we already do) |
| E3 | `Unsupported cache type: turbo3` | Wrong branch (`master` has no TurboQuant) | Clone `--branch feature/turboquant-kv-cache` |
| E4 | `Abort trap: 6` on model load with `-ctk turbo3` | turbo3 kernel doesn't handle every head-dim / quant — confirmed for `tiny` (head dim too small) and `gpt-oss-20b` (MXFP4) | Pin `KV=q8_0` for those models (their per-model targets already do) |
| E5 | Port `:10501` (or `:11500`) already in use on launch | LM Studio default server, leftover llama-server, or proxy still running | `ensure_port_free` aborts with a hint; `make stop` or `lsof -nP -iTCP:10501 -sTCP:LISTEN` then kill |

### Privacy / static-check gate failures (CI / pre-push)
`scripts/static-check.sh` runs shell + Python syntax, unit tests, and `make help`; `scripts/privacy-scan.sh` greps the tree for personal paths, names, and credential-shaped tokens (`gh[ps]_…`, `sk-…`, PEM blocks, `Bearer …`, `/Users/you`, `/path/to/project`, etc.) and exits non-zero on a hit. The pre-push hook in `scripts/git-hooks/` runs both. If the gate fails:
- For the privacy scan, the offending file:line is printed — replace the literal with a placeholder (`/path/to/repo`) or scrub it.
- For static-check, look at `/tmp/qwen-static-tests.log` for unittest output.
