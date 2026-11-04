# Local model experiments

Run commands from the repository root:

```bash
python3 scripts/experimental-models.py list
python3 scripts/experimental-models.py start crow-9b --dry-run
python3 scripts/experimental-models.py start crow-9b
```

Other profiles: `mimo-9b`, `journalist-9b`, `lfm3-1.7b`.
Open http://127.0.0.1:10502/ for chat; the API base is
`http://127.0.0.1:10502/v1`. Ctrl+C stops the foreground experiment.
The launcher refuses occupied ports and never stops other services.
Use `--port 10503` for a deliberate parallel comparison, `--ctx 8192` for
longer context (maximum 32768), or `--engine /path/to/llama-server` for
an explicit compatible runtime.

LFM3 Q8_0 is downloaded and SHA-256 verified. Start it with:

```bash
python3 scripts/experimental-models.py start lfm3-1.7b
```

Its separate runtime and embedded chat template passed a bounded local
completion check. The launcher performs no downloads.

## Research and selected artifacts

Checked 2026-11-03 using [Liquid's model card](https://huggingface.co/LiquidAI/LFM3-1.7B),
[official GGUFs](https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF),
[deployment guide](https://docs.liquid.ai/deployment/on-device/llama-cpp),
and [llama.cpp v0.8.0 release](https://github.com/ggml-org/llama.cpp/releases/tag/v0.8.0).
LFM3 requires b11960 / v0.8.0 or newer; existing August engines predate
LFM3. A checksum-verified official Apple Silicon b11960 runtime is installed
separately in `vendor/llama.cpp-lfm3/bin` with its MIT license and provenance.
The existing engines and primary-service settings are preserved.

The inspected Mac is an M3 Max with 64 GiB unified memory. Selected LFM3
Q8_0 is 1,846,238,496 bytes, a small quality baseline for this machine.
Liquid recommends Q4_K_M for a size/quality balance; Q8_0 is the only
LFM checkpoint selected for download. NVFP4 targets NVIDIA Blackwell.

Crow, MiMo Ablitrated and abliterated Journalist 9B GGUFs are reused directly
from their existing locations under `~/.lmstudio/models`; no Qwen models or
projectors are copied or downloaded. These profiles use the existing
mainline engine. This experiment is text-only and uses embedded Jinja
chat templates with ordinary f16 KV cache, Metal offload, two CPU threads,
low process priority, one slot and 4096-token context. It enables no agent
or MCP tools, projectors, speculative decoding or YaRN overrides.
Inherited `LLAMA_ARG_*` settings are removed from the child environment.

LFM3 sampling follows Liquid's general guidance: temperature 0.1,
top-k 50, repetition penalty 1.1; top-p 1.0 and min-p 0 disable extra filters.
Liquid describes the 1.73B model as suited for extraction, local assistants,
tool use and specialization, and cautions about complex reasoning and
agentic coding. Short completion tests do not establish those capabilities
or assess publisher claims about Qwen derivative behavior.

## Verified LFM3 artifact

Pinned URLs, sizes and hashes are recorded in
`configs/experimental-models.lock.json`. The local model is
`models/experimental/LFM3-1.7B-Q8_0.gguf`, 1,846,238,496 bytes, SHA-256
`8f6b24182258205e9e01e21f1f24a1f208c1e8115578825d202ce39976af20b6`.
The existing partial download was resumed with the user's approval and
verified before being renamed; no second checkpoint was downloaded.

For recovery, check for a complete verified file and any active transfer
first. If a partial file exists, resume the pinned URL using curl
`--continue-at -` and verify the expected size and SHA-256 before enabling it.

The complete LFM Open License v1.0 is copied beside the model as
`LICENSE-LFM3.txt`. Local experimentation is covered; commercial use is
subject to the license's $10 million annual-revenue condition. Redistribution
requires the license and relevant notices; consult the full terms.
Crow's publisher lists Apache-2.0; MiMo's lists MIT. Journalist's upstream
page was unavailable during this review; preserve its local metadata.

## Checks

```bash
python3 -m unittest discover -s tests -p test_experimental_models.py
```

Local results live in `logs/lfm3-workstream/`. All 59 unit tests pass.
Each of the four profiles passed a bounded local arithmetic completion
check; all test servers exited cleanly. These are functional checks, not
performance benchmarks. No experiment is registered with launchd.

## Reasoning mode caveat

Keep LFM3's default thinking enabled for initial experiments. The bounded
default-mode arithmetic check returned `4`. With `enable_thinking: false`,
the same arithmetic probe returned `2`, and a capital-city probe emitted
`Paris</think>Paris`. These failures are preserved in the local check logs.
[LiquidAI's author describes disabling thinking as unreliable](https://huggingface.co/LiquidAI/LFM3-1.7B/discussions/20).
The launcher retains the native template and default reasoning behavior.
Functional integration is verified; this is not a broad quality evaluation.
