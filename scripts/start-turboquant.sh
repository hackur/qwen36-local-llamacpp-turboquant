#!/usr/bin/env bash
# Start TurboQuant llama-server (turbo3 KV cache, 128K ctx) on :10501.
# Falls back to q8_0 KV cache if the binary doesn't recognize turbo3.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

PORT="${PORT:-10501}"
CTX="${CTX:-131072}"
MODEL="${MODEL:-$MODEL_PRIMARY}"
KV="${KV:-turbo3}"   # turbo2 / turbo3 / turbo4 / q8_0 / q4_0 / f16
BIN="$REPO/vendor/llama-cpp-turboquant/build/bin/llama-server"
LOG="$REPO/logs/turboquant.log"

[[ -x "$BIN" ]] || { echo "❌ TurboQuant fork not built. Run scripts/build-llama.sh"; exit 1; }
ensure_model "$MODEL"
ensure_port_free "$PORT"
mkdir -p "$REPO/logs"

# Probe the binary for the requested cache type.
if ! "$BIN" -h 2>&1 | grep -q -- "$KV"; then
  echo "⚠  '$KV' not in this build's --cache-type help."
  echo "   Available cache types in this build:"
  "$BIN" -h 2>&1 | grep -A2 -i "cache.type" | head -10
  echo "   Falling back to KV=q8_0"
  KV=q8_0
fi

echo "▶ turboquant @ http://127.0.0.1:$PORT  (KV=$KV, ${CTX} ctx)"
echo "  TURBO_LAYER_ADAPTIVE=1   log → $LOG"
TURBO_LAYER_ADAPTIVE=1 exec "$BIN" \
  -m "$MODEL" \
  --port "$PORT" \
  -c "$CTX" \
  -ctk "$KV" -ctv "$KV" \
  "${COMMON[@]}" \
  "${SAMPLING[@]}" \
  --alias qwen3.6-turboquant \
  2>&1 | tee "$LOG"
