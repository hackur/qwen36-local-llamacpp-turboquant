#!/usr/bin/env bash
# Start mainline llama-server (control: f16 KV cache, 32K ctx) on :10500.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

PORT="${PORT:-10500}"
CTX="${CTX:-32768}"
MODEL="${MODEL:-$MODEL_PRIMARY}"
BIN="$REPO/vendor/llama.cpp-mainline/build/bin/llama-server"
LOG="$REPO/logs/baseline.log"

[[ -x "$BIN" ]] || { echo "❌ Mainline not built. Run scripts/build-llama.sh"; exit 1; }
ensure_model "$MODEL"
ensure_port_free "$PORT"
mkdir -p "$REPO/logs"

echo "▶ baseline @ http://127.0.0.1:$PORT (f16 KV, ${CTX} ctx)"
echo "  log → $LOG"
exec "$BIN" \
  -m "$MODEL" \
  --port "$PORT" \
  -c "$CTX" \
  "${COMMON[@]}" \
  "${SAMPLING[@]}" \
  --alias qwen3.6-baseline \
  2>&1 | tee "$LOG"
