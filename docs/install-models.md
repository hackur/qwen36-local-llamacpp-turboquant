# Installing models without LM Studio

The default path uses LM Studio's `~/.lmstudio/models/...` layout because it's
convenient, but the stack works fine with any directory of GGUFs. Two routes:

## A. Already in LM Studio (default)

```bash
./scripts/symlink-models.sh                    # picks up everything it knows about
```

## B. Custom location (no LM Studio)

`scripts/symlink-models.sh` accepts `MODELS_ROOT=<dir>`. Lay out the
directory tree to mirror what the script expects, then run:

```bash
MODELS_ROOT=/path/to/your/ggufs ./scripts/symlink-models.sh
```

The expected sub-paths under `$MODELS_ROOT` (matching what LM Studio creates,
matching what `huggingface-cli download` lays out by default):

| Alias | Path under `$MODELS_ROOT` |
|---|---|
| `qwen38-27b` (default) | `lmstudio-community/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q8_0.gguf` (+ `mmproj-Qwen3.8-27B-BF16.gguf`) |
| `qwen36-neo` | `DavidAU/Qwen3.6-27B-Heretic-Uncensored-FINETUNE-NEO-CODE-Di-IMatrix-MAX-GGUF/Qwen3.6-27B-NEO-CODE-HERE-2T-OT-Q5_K_M.gguf` (+ `mmproj-F32.gguf`) |
| `qwen36-35b` | `lmstudio-community/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-Q6_K.gguf` (+ `mmproj-Qwen3.6-35B-A3B-BF16.gguf`) |
| `qwen36-27b` | `unsloth/Qwen3.6-27B-GGUF/Qwen3.6-27B-UD-IQ2_XXS.gguf` (+ `mmproj-F32.gguf`) |
| `gemma4-26b` | `lmstudio-community/gemma-4-26B-A4B-it-GGUF/gemma-4-26B-A4B-it-Q4_K_M.gguf` (+ `mmproj-gemma-4-26B-A4B-it-BF16.gguf`) |
| `gemma4-e4b` | `lmstudio-community/gemma-4-E4B-it-GGUF/gemma-4-E4B-it-Q8_0.gguf` (+ `mmproj-gemma-4-E4B-it-BF16.gguf`) |
| `gpt-oss-20b` | `lmstudio-community/gpt-oss-20b-GGUF/gpt-oss-20b-MXFP4.gguf` |
| `qwen35-9b` | `lmstudio-community/Qwen3.5-9B-GGUF/Qwen3.5-9B-Q8_0.gguf` (+ `mmproj-Qwen3.5-9B-BF16.gguf`) |
| `qwen3.5-0.8b` | `unsloth/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q8_0.gguf` (no mmproj, ~775 MB) |
| `crow-9b` | `mradermacher/Crow-9B-Opus-4.6-Distill-Heretic_Qwen3.5-GGUF/Crow-9B-Opus-4.6-Distill-Heretic_Qwen3.5.Q4_K_S.gguf` (+ `Crow-9B-Opus-4.6-Distill-Heretic_Qwen3.5.mmproj-f16.gguf`) |
| `nemotron-4b` | `lmstudio-community/NVIDIA-Nemotron-3-Nano-4B-GGUF/NVIDIA-Nemotron-3-Nano-4B-Q4_K_M.gguf` |
| `tiny` | `TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf` |

Anything you didn't download will be reported as `(skip — not in LM Studio: …)`
when you run the script (the message says "LM Studio" even when `MODELS_ROOT`
points elsewhere). That's not an error — the start scripts just won't list
those aliases in `make models`.

## C. Bypass aliases entirely — point `MODEL=` at any GGUF

```bash
MODEL=/absolute/path/to/your-model.gguf CTX=8192 KV=q8_0 ./scripts/start-turboquant.sh
```

`scripts/_common.sh` treats any `MODEL` value containing `/` or ending in
`.gguf` as a literal path and skips the alias resolver. Useful for one-off
tests.

## Downloading via huggingface-cli

If you don't want LM Studio at all:

```bash
brew install huggingface-cli   # or: pip install -U "huggingface_hub[cli]"

# Default destination is $HF_HOME (typically ~/.cache/huggingface). Pass
# --local-dir to mirror LM Studio's layout. Example for the Qwen3.8 default:
mkdir -p ~/ggufs/lmstudio-community/Qwen3.8-27B-GGUF
huggingface-cli download lmstudio-community/Qwen3.8-27B-GGUF \
  Qwen3.8-27B-Q8_0.gguf mmproj-Qwen3.8-27B-BF16.gguf \
  --local-dir ~/ggufs/lmstudio-community/Qwen3.8-27B-GGUF \
  --local-dir-use-symlinks False

# then:
MODELS_ROOT=~/ggufs ./scripts/symlink-models.sh
```

The download itself needs network; once done, everything is offline.

When adding a new alias, also add a `case` branch to [`configs/model-defaults.env`](../configs/model-defaults.env) — that's where per-model CTX / KV / RoPE defaults live.

## After symlinking

```bash
make models      # confirms what's wired up
make start       # default model: qwen38-27b + embedded MTP
```

If you only downloaded a smaller model, edit your default with
`MODEL=<alias> make start`.
