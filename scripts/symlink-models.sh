#!/usr/bin/env bash
# Symlink the LM Studio GGUFs into ./models/ so the project is self-contained
# without a 30 GB copy. If LM Studio reorganizes someday, only this file changes.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$REPO/models"

link() {
  local target="$1" name="$2"
  if [[ ! -f "$target" ]]; then echo "  skip (missing): $target"; return; fi
  ln -sf "$target" "$REPO/models/$name"
  echo "  ./models/$name → $target"
}

echo "▶ Linking GGUFs into $REPO/models/"
link "$HOME/.lmstudio/models/lmstudio-community/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-Q6_K.gguf" "Qwen3.6-35B-A3B-Q6_K.gguf"
link "$HOME/.lmstudio/models/lmstudio-community/Qwen3.6-35B-A3B-GGUF/mmproj-Qwen3.6-35B-A3B-BF16.gguf" "mmproj-Qwen3.6-35B-A3B.gguf"
link "$HOME/.lmstudio/models/unsloth/Qwen3.6-27B-GGUF/Qwen3.6-27B-UD-IQ2_XXS.gguf" "Qwen3.6-27B-IQ2_XXS.gguf"
link "$HOME/.lmstudio/models/unsloth/Qwen3.6-27B-GGUF/mmproj-F32.gguf" "mmproj-Qwen3.6-27B.gguf"

ls -lh "$REPO/models/"
