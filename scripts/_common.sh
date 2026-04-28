#!/usr/bin/env bash
# Shared env for start scripts.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Primary model — Qwen3.6-35B-A3B Q6_K (28.5 GB, MoE ~3B active)
MODEL_PRIMARY="$HOME/.lmstudio/models/lmstudio-community/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-Q6_K.gguf"
MMPROJ_PRIMARY="$HOME/.lmstudio/models/lmstudio-community/Qwen3.6-35B-A3B-GGUF/mmproj-Qwen3.6-35B-A3B-BF16.gguf"

# Fallback — Qwen3.6-27B IQ2_XXS (9.4 GB)
MODEL_FALLBACK="$HOME/.lmstudio/models/unsloth/Qwen3.6-27B-GGUF/Qwen3.6-27B-UD-IQ2_XXS.gguf"
MMPROJ_FALLBACK="$HOME/.lmstudio/models/unsloth/Qwen3.6-27B-GGUF/mmproj-F32.gguf"

# Sampling per Qwen team recommendations (thinking/coding)
SAMPLING=(--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0)

# Common server args
COMMON=(-ngl 99 -fa on -np 1 --host 127.0.0.1 --jinja)

ensure_port_free() {
  local port="$1"
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "❌ Port $port already in use. Is LM Studio's server (default :1234) or another llama-server running?"
    lsof -nP -iTCP:"$port" -sTCP:LISTEN
    exit 1
  fi
}

ensure_model() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "❌ Model missing: $path"
    echo "   Open LM Studio → Models tab to download, or fix the path."
    exit 1
  fi
}
