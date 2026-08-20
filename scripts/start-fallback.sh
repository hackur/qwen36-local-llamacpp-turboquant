#!/usr/bin/env bash
# Start mainline llama-server with q8_0 KV cache + 64K context on :10502.
# This path is fully Metal-supported and is the safety net if turbo3 fails.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

PORT="${PORT:-10502}"
CTX="${CTX:-65536}"
MODEL_INPUT="${MODEL:-$MODEL_PRIMARY_ALIAS}"
BIN="$REPO/vendor/llama.cpp-mainline/build/bin/llama-server"
LOG="$REPO/logs/fallback.log"

[[ -x "$BIN" ]] || { echo "❌ Mainline not built. Run scripts/build-llama.sh"; exit 1; }
resolve_model "$MODEL_INPUT"
MODEL="$RESOLVED_MODEL"
ensure_model "$MODEL"
if (( ! DRY_RUN )); then
  ensure_no_other_llama_server
  ensure_port_free "$PORT"
fi
mkdir -p "$REPO/logs"

# Froggeric Qwen-Fixed-Chat-Templates v19 for Qwen 3.5/3.6 aliases (no-op otherwise).
# shellcheck disable=SC2207
TEMPLATE_FLAGS=( $(chat_template_flags "$MODEL_INPUT") )

echo "▶ fallback @ http://127.0.0.1:$PORT  (q8_0 KV, ${CTX} ctx)"
if (( DRY_RUN )); then
  printf "dry-run:"
  printf " %q" exec "$BIN" \
    -m "$MODEL" \
    --port "$PORT" \
    -c "$CTX" \
    -ctk q8_0 -ctv q8_0 \
    "${COMMON[@]}" \
    "${SAMPLING[@]}" \
    ${TEMPLATE_FLAGS[@]+"${TEMPLATE_FLAGS[@]}"} \
    --alias qwen3.8-q8
  printf " 2>&1 | tee %q\n" "$LOG"
  exit 0
fi

exec "$BIN" \
  -m "$MODEL" \
  --port "$PORT" \
  -c "$CTX" \
  -ctk q8_0 -ctv q8_0 \
  "${COMMON[@]}" \
  "${SAMPLING[@]}" \
  ${TEMPLATE_FLAGS[@]+"${TEMPLATE_FLAGS[@]}"} \
  --alias qwen3.8-q8 \
  2>&1 | tee "$LOG"
