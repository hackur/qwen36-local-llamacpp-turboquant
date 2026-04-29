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
LM Studio's default server is on **:1234**. We use **:10500/10501/10502**. If something already holds those:
```bash
lsof -nP -iTCP:10501 -sTCP:LISTEN
```
Kill the holder or set `PORT=10503 ./scripts/start-turboquant.sh`.

### Model file not found
Open LM Studio → Models, confirm the GGUF is downloaded. Or override:
```bash
MODEL=/some/other/path.gguf ./scripts/start-baseline.sh
```

## Runtime

### Tok/s is half what was advertised
- macOS Activity Monitor → Energy → confirm power source. Plugged-in M3 Max scores ~30% better than on-battery.
- Other GPU work in flight (Final Cut, video calls) steals Metal time.
- Confirm `-ngl 99` (all layers on GPU). With 0, llama.cpp runs CPU-only.
- Confirm `-fa on` (flash attention) — without it, prompt-eval drops a lot.

### "Prompt too long" at 100K tokens
- Confirm the server was started with `-c 131072` (default in `start-turboquant.sh`).
- If the build ran out of memory allocating the KV cache at start, it would have logged "ggml_metal: failed to allocate buffer". Reduce `-c` or use a smaller KV type.

### Quality regression on TurboQuant vs baseline
Run `scripts/quality-check.sh` and diff outputs. turbo3 trades some bits for context — if a prompt is sensitive to recall fidelity, route it to baseline (port 10500).

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

## Five known errors from the upstream guide

These come from the iflow-mcp + Hugging Face TurboQuant guide. Most are CUDA-specific; we still get bitten by the first two in spirit:

| # | Symptom | Cause | Fix |
|---|---|---|---|
| E1 | `llama-server -h \| grep turbo` empty | Wrong repo (`turboquant_plus` is a Python lib) | Use `TheTom/llama-cpp-turboquant` |
| E2 | Build succeeds but inference is slow | Old cmake flag `-DLLAMA_CUBLAS=ON` silently ignored | Use `-DGGML_METAL=ON` (we already do) |
| E3 | Linker error on `libcuda.so.1` | n/a on macOS | n/a |
| E4 | `Unsupported cache type: turbo3` | Wrong branch (`master` has no TurboQuant) | Clone `--branch feature/turboquant-kv-cache` |
| E5 | 404 on model download | HF repo renamed | We don't download — we re-use LM Studio's local files |
