#!/usr/bin/env bash
# Start TurboQuant server with the multimodal projector loaded (vision-capable).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi

PORT="${PORT:-10503}"
CTX="${CTX:-32768}"
MODEL_INPUT="${MODEL:-$MODEL_PRIMARY_ALIAS}"
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
if (( ! DRY_RUN )); then
  ensure_no_other_llama_server
  ensure_port_free "$PORT"
  # memory-preflight:v1 — vision combos (text server on :10501 + this on :10503)
  # can OOM a 64 GB box. Helper lives in _common.sh; always on for vision.
  preflight_memory "$MODEL" "$MMPROJ"
fi

mkdir -p "$REPO/logs"

HELP_OUT=$("$BIN" -h 2>&1 || true)
if ! grep -q -- "$KV" <<< "$HELP_OUT"; then KV=q8_0; fi

# mixed-kv-guard:v1 — derive KV_K / KV_V from KV (unless overridden) and warn on mismatch.
apply_kv_split

MTP_FLAGS=()
if [[ "$MODEL_INPUT" == "qwen38-27b" ]]; then
  echo "⚠️  Current Qwen3.8 vision requests log harmless non-consecutive token-position warnings; output was verified correct." >&2
fi
if [[ "$MODEL_INPUT" == "qwen38-27b" && "${MTP:-0}" == "1" ]]; then
  grep -q "draft-mtp" <<< "$HELP_OUT" || { echo "❌ Current binary lacks draft-mtp" >&2; exit 1; }
  echo "⚠️  Vision + MTP remains experimental; text-only MTP is the production default." >&2
  MTP_FLAGS=(--spec-type draft-mtp --spec-draft-n-max "${SPEC_N_MAX:-3}" --spec-draft-p-min "${SPEC_P_MIN:-0.5}")
fi

KV_DESC="$KV_K"; [[ "$KV_K" != "$KV_V" ]] && KV_DESC="${KV_K}/${KV_V}"
echo "▶ vision @ http://127.0.0.1:$PORT  (KV=$KV_DESC, ${CTX} ctx, mmproj loaded)"
if (( DRY_RUN )); then
  printf "dry-run:"
  printf " %q" TURBO_LAYER_ADAPTIVE=1 exec "$BIN" \
    -m "$MODEL" \
    --mmproj "$MMPROJ" \
    --port "$PORT" \
    -c "$CTX" \
    -ctk "$KV_K" -ctv "$KV_V" \
    "${COMMON[@]}" \
    "${SAMPLING[@]}" \
    ${MTP_FLAGS[@]+"${MTP_FLAGS[@]}"} \
    --alias qwen3.8-vision
  printf " 2>&1 | tee %q\n" "$LOG"
  exit 0
fi

TURBO_LAYER_ADAPTIVE=1 exec "$BIN" \
  -m "$MODEL" \
  --mmproj "$MMPROJ" \
  --port "$PORT" \
  -c "$CTX" \
  -ctk "$KV_K" -ctv "$KV_V" \
  "${COMMON[@]}" \
  "${SAMPLING[@]}" \
  ${MTP_FLAGS[@]+"${MTP_FLAGS[@]}"} \
  --alias qwen3.8-vision \
  2>&1 | tee "$LOG"
