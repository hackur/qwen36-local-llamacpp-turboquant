#!/usr/bin/env bash
# Start mainline llama-server with q8_0 KV cache + 64K context on :10502.
# This path is fully Metal-supported and is the safety net if turbo3 fails.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

PORT="${PORT:-10502}"
CTX="${CTX:-65536}"
MODEL_INPUT="${MODEL:-$MODEL_PRIMARY}"
BIN="$REPO/vendor/llama.cpp-mainline/build/bin/llama-server"
LOG="$REPO/logs/fallback.log"

[[ -x "$BIN" ]] || { echo "❌ Mainline not built. Run scripts/build-llama.sh"; exit 1; }
resolve_model "$MODEL_INPUT"
MODEL="$RESOLVED_MODEL"
ensure_model "$MODEL"
ensure_port_free "$PORT"
mkdir -p "$REPO/logs"

echo "▶ fallback @ http://127.0.0.1:$PORT  (q8_0 KV, ${CTX} ctx)"
exec "$BIN" \
  -m "$MODEL" \
  --port "$PORT" \
  -c "$CTX" \
  -ctk q8_0 -ctv q8_0 \
  "${COMMON[@]}" \
  "${SAMPLING[@]}" \
  --alias qwen3.6-q8 \
  2>&1 | tee "$LOG"
