# start-summarizer.sh

Launches the small summarizer `llama-server` on `:10503` for the compaction
proxy (see `docs/compaction-strategy.md` §4). It runs alongside the primary
35B on `:10501` so summarization happens out-of-band without blocking the
agent's main turn.

## Usage

```
proxy/scripts/start-summarizer.sh                # gemma4-e4b on GPU
proxy/scripts/start-summarizer.sh --cpu-only     # free VRAM for the primary
SUMMARIZER_MODEL=nemotron-4b proxy/scripts/start-summarizer.sh
PORT=10503 CTX=16384 NGL=99 proxy/scripts/start-summarizer.sh
proxy/scripts/start-summarizer.sh --dry-run      # print command, do not exec
```

If a server is already listening on `:10503`, the script prints a notice and
exits 0 (idempotent). Logs append to `~/.cache/qwen-compact/logs/summarizer.log`.

## Model choice (§4 + §11)

Three candidates are supported. Tradeoffs:

| Model            | File (alias)        | Size on disk | Quality | Speed (M3 Max GPU) | Notes |
|------------------|---------------------|--------------|---------|--------------------|-------|
| `gemma4-e4b`     | `models/gemma4-e4b.gguf` | ~8 GB     | best    | ~51 tok/s          | Default. Highest summary fidelity; tightest memory budget. |
| `nemotron-4b`    | `models/nemotron-4b.gguf` | ~2.8 GB  | good    | ~98 tok/s          | Fastest with reasonable quality. Best general pick if VRAM is tight. |
| `tiny`           | `models/tiny.gguf`        | very small | low      | very fast          | Last-resort. Quality regressions likely; pair with the sumy fallback (Tier 4). |

§11 leaves the final pick open pending the decision-preservation eval; bench
all three on real session traces before committing.

### CPU vs GPU (§11 open question)

The 4B-class models are small enough to summarize at 10–20 tok/s on CPU, which
is fine for a background task and frees ~3–8 GB of unified memory for the
primary 35B's KV cache. Use `--cpu-only` when running the primary at high
context and pressure starts hurting prefill latency. On GPU the same models
hit ~50–100 tok/s.

## Model paths

The launcher expects `.gguf` files under `<repo>/models/`. The following
files are present in this repo and are valid `SUMMARIZER_MODEL` aliases:

- `models/gemma4-e4b.gguf` (default)
- `models/nemotron-4b.gguf`
- `models/tiny.gguf`

You can also pass an absolute path via `SUMMARIZER_MODEL=/full/path.gguf`.

If a model is missing, download it into `models/` via LM Studio (Models tab)
or any GGUF source matching the alias name, then run `scripts/symlink-models.sh`
if you keep canonical files elsewhere. The launcher does **not** auto-download.

## Conventions

The script mirrors `scripts/start-turboquant.sh`:

- `set -euo pipefail`
- single slot (`-np 1`), `127.0.0.1` only, `--jinja` for chat templates
- flash-attention on GPU; off in `--cpu-only` mode
- `--dry-run` prints the exec line instead of running it
- model resolution via `scripts/_common.sh::resolve_model` when available
