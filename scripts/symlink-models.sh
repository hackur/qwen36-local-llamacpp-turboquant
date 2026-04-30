#!/usr/bin/env bash
# Symlink LM Studio's GGUFs into ./models/ so the project is self-contained
# without copying ~80 GB. Idempotent — reruns just refresh the links.
# Adding a new model? Add an entry to MODELS below.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

run() {
  if (( DRY_RUN )); then
    printf "  dry-run: %q" "$1"
    shift
    printf " %q" "$@"
    printf "\n"
  else
    "$@"
  fi
}

if (( DRY_RUN )); then
  echo "dry-run: no files will be changed"
else
  mkdir -p "$REPO/models"
fi

# Wipe pre-alias-scheme symlinks (older runs created descriptive names like
# `Qwen3.6-35B-A3B-Q6_K.gguf` and `mmproj-Qwen3.6-27B.gguf`). Keep only
# `<alias>.gguf` and `<alias>.mmproj.gguf`.
for old in "$REPO/models/Qwen3.6-27B-IQ2_XXS.gguf" \
           "$REPO/models/Qwen3.6-35B-A3B-Q6_K.gguf" \
           "$REPO/models/mmproj-Qwen3.6-27B.gguf" \
           "$REPO/models/mmproj-Qwen3.6-35B-A3B.gguf"; do
  [[ -L "$old" ]] && { run rm -f "$old"; echo "  rm (pre-alias) $(basename "$old")"; }
done

# alias  weight-source-relpath                                                                              mmproj-source-relpath (or "" if none)
MODELS=(
  "qwen36-35b   lmstudio-community/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-Q6_K.gguf                                       lmstudio-community/Qwen3.6-35B-A3B-GGUF/mmproj-Qwen3.6-35B-A3B-BF16.gguf"
  "qwen36-27b   unsloth/Qwen3.6-27B-GGUF/Qwen3.6-27B-UD-IQ2_XXS.gguf                                                    unsloth/Qwen3.6-27B-GGUF/mmproj-F32.gguf"
  "gemma4-26b   lmstudio-community/gemma-4-26B-A4B-it-GGUF/gemma-4-26B-A4B-it-Q4_K_M.gguf                               lmstudio-community/gemma-4-26B-A4B-it-GGUF/mmproj-gemma-4-26B-A4B-it-BF16.gguf"
  "gemma4-e4b   lmstudio-community/gemma-4-E4B-it-GGUF/gemma-4-E4B-it-Q8_0.gguf                                         lmstudio-community/gemma-4-E4B-it-GGUF/mmproj-gemma-4-E4B-it-BF16.gguf"
  "gpt-oss-20b  lmstudio-community/gpt-oss-20b-GGUF/gpt-oss-20b-MXFP4.gguf                                              "
  "qwen35-9b    lmstudio-community/Qwen3.5-9B-GGUF/Qwen3.5-9B-Q8_0.gguf                                                 lmstudio-community/Qwen3.5-9B-GGUF/mmproj-Qwen3.5-9B-BF16.gguf"
  "crow-9b      mradermacher/Crow-9B-Opus-4.6-Distill-Heretic_Qwen3.5-GGUF/Crow-9B-Opus-4.6-Distill-Heretic_Qwen3.5.Q4_K_S.gguf  mradermacher/Crow-9B-Opus-4.6-Distill-Heretic_Qwen3.5-GGUF/Crow-9B-Opus-4.6-Distill-Heretic_Qwen3.5.mmproj-f16.gguf"
  "nemotron-4b  lmstudio-community/NVIDIA-Nemotron-3-Nano-4B-GGUF/NVIDIA-Nemotron-3-Nano-4B-Q4_K_M.gguf                 "
  "tiny         TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf                             "
)

LMSTUDIO_ROOT="$HOME/.lmstudio/models"
ok=0; missing=0
for entry in "${MODELS[@]}"; do
  read -r alias weight mmproj <<< "$entry"
  src="$LMSTUDIO_ROOT/$weight"
  if [[ -f "$src" ]]; then
    run ln -sf "$src" "$REPO/models/$alias.gguf"
    printf "  %-13s ./models/%s.gguf\n" "$alias" "$alias"
    ok=$((ok+1))
  else
    printf "  %-13s (skip — not in LM Studio: %s)\n" "$alias" "$weight"
    missing=$((missing+1))
    continue
  fi
  if [[ -n "${mmproj:-}" ]]; then
    msrc="$LMSTUDIO_ROOT/$mmproj"
    if [[ -f "$msrc" ]]; then
      run ln -sf "$msrc" "$REPO/models/$alias.mmproj.gguf"
      printf "                ./models/%s.mmproj.gguf\n" "$alias"
    fi
  fi
done

echo
if (( DRY_RUN )); then
  echo "✓ would link $ok models ($missing missing). Use them via: MODEL=<alias> ./scripts/start-turboquant.sh"
else
  echo "✓ linked $ok models ($missing missing). Use them via: MODEL=<alias> ./scripts/start-turboquant.sh"
fi
