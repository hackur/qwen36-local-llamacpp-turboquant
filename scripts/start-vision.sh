#!/usr/bin/env bash
# Start TurboQuant server with the multimodal projector loaded (vision-capable).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

PORT="${PORT:-10503}"
CTX="${CTX:-32768}"
MODEL="${MODEL:-$MODEL_PRIMARY}"
MMPROJ="${MMPROJ:-$MMPROJ_PRIMARY}"
KV="${KV:-turbo3}"
BIN="$REPO/vendor/llama-cpp-turboquant/build/bin/llama-server"
LOG="$REPO/logs/vision.log"

[[ -x "$BIN" ]] || { echo "❌ TurboQuant fork not built"; exit 1; }
ensure_model "$MODEL"
ensure_model "$MMPROJ"
ensure_port_free "$PORT"
mkdir -p "$REPO/logs"

if ! "$BIN" -h 2>&1 | grep -q -- "$KV"; then KV=q8_0; fi

echo "▶ vision @ http://127.0.0.1:$PORT  (KV=$KV, ${CTX} ctx, mmproj loaded)"
TURBO_LAYER_ADAPTIVE=1 exec "$BIN" \
  -m "$MODEL" \
  --mmproj "$MMPROJ" \
  --port "$PORT" \
  -c "$CTX" \
  -ctk "$KV" -ctv "$KV" \
  "${COMMON[@]}" \
  "${SAMPLING[@]}" \
  --alias qwen3.6-vision \
  2>&1 | tee "$LOG"
