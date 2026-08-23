#!/usr/bin/env bash
# Link the only supported artifacts into ./models without copying 28 GiB.
# Existing non-Qwen3.8 GGUF symlinks in this repository are pruned; their
# source files in LM Studio or MODELS_ROOT are never modified.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

MODELS_ROOT="${MODELS_ROOT:-$HOME/.lmstudio/models}"
WEIGHT_REL="lmstudio-community/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q8_0.gguf"
MMPROJ_REL="lmstudio-community/Qwen3.8-27B-GGUF/mmproj-Qwen3.8-27B-BF16.gguf"
WEIGHT_SRC="$MODELS_ROOT/$WEIGHT_REL"
MMPROJ_SRC="$MODELS_ROOT/$MMPROJ_REL"
WEIGHT_LINK="$REPO/models/qwen38-27b.gguf"
MMPROJ_LINK="$REPO/models/qwen38-27b.mmproj.gguf"

run() {
  if (( DRY_RUN )); then
    printf 'dry-run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

[[ -f "$WEIGHT_SRC" ]] || {
  echo "missing Qwen3.8 weights: $WEIGHT_SRC" >&2
  exit 1
}
[[ -f "$MMPROJ_SRC" ]] || {
  echo "missing Qwen3.8 projector: $MMPROJ_SRC" >&2
  exit 1
}

run mkdir -p "$REPO/models"
shopt -s nullglob
for link in "$REPO"/models/*.gguf; do
  [[ -L "$link" ]] || continue
  case "$(basename "$link")" in
    qwen38-27b.gguf|qwen38-27b.mmproj.gguf) ;;
    *)
      echo "pruning legacy project symlink: ${link#$REPO/}"
      run unlink "$link"
      ;;
  esac
done

run ln -sfn "$WEIGHT_SRC" "$WEIGHT_LINK"
run ln -sfn "$MMPROJ_SRC" "$MMPROJ_LINK"

echo "Qwen3.8 project artifacts:"
echo "  models/qwen38-27b.gguf -> $WEIGHT_SRC"
echo "  models/qwen38-27b.mmproj.gguf -> $MMPROJ_SRC"
(( DRY_RUN )) && echo "No files were changed."
