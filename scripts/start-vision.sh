#!/usr/bin/env bash
# Start TurboQuant server with the multimodal projector loaded (vision-capable).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

PORT="${PORT:-10503}"
CTX="${CTX:-32768}"
MODEL_INPUT="${MODEL:-qwen36-35b}"
KV="${KV:-turbo3}"
BIN="$REPO/vendor/llama-cpp-turboquant/build/bin/llama-server"
LOG="$REPO/logs/vision.log"

[[ -x "$BIN" ]] || { echo "❌ TurboQuant fork not built"; exit 1; }
resolve_model "$MODEL_INPUT"
MODEL="$RESOLVED_MODEL"
ensure_model "$MODEL"
load_model_defaults "$MODEL_INPUT"
MMPROJ="${MMPROJ:-${RESOLVED_MMPROJ:-}}"
if [[ -z "$MMPROJ" || ! -f "$MMPROJ" ]]; then
  echo "❌ No mmproj for '$MODEL_INPUT'. Pick a multimodal model:"
  ls "$REPO/models/"*.mmproj.gguf 2>/dev/null | sed 's/.mmproj.gguf$//; s|.*/||; s/^/  /'
  exit 1
fi
ensure_model "$MMPROJ"
ensure_no_other_llama_server
ensure_port_free "$PORT"

# memory-preflight:v1 — vision combos (text server on :10501 + this on :10503)
# can OOM a 64 GB box. Helper lives in _common.sh; always on for vision.
preflight_memory "$MODEL" "$MMPROJ"

mkdir -p "$REPO/logs"

if ! "$BIN" -h 2>&1 | grep -q -- "$KV"; then KV=q8_0; fi

# mixed-kv-guard:v1 — derive KV_K / KV_V from KV (unless overridden) and warn on mismatch.
apply_kv_split

KV_DESC="$KV_K"; [[ "$KV_K" != "$KV_V" ]] && KV_DESC="${KV_K}/${KV_V}"
echo "▶ vision @ http://127.0.0.1:$PORT  (KV=$KV_DESC, ${CTX} ctx, mmproj loaded)"
TURBO_LAYER_ADAPTIVE=1 exec "$BIN" \
  -m "$MODEL" \
  --mmproj "$MMPROJ" \
  --port "$PORT" \
  -c "$CTX" \
  -ctk "$KV_K" -ctv "$KV_V" \
  "${COMMON[@]}" \
  "${SAMPLING[@]}" \
  --alias qwen3.6-vision \
  2>&1 | tee "$LOG"
