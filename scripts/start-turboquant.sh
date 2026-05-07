#!/usr/bin/env bash
# Start TurboQuant llama-server (turbo3 KV cache, 128K ctx) on :10501.
# Falls back to q8_0 KV cache if the binary doesn't recognize turbo3.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

PORT="${PORT:-10501}"
MODEL_INPUT="${MODEL:-$MODEL_PRIMARY}"
BIN="$REPO/vendor/llama-cpp-turboquant/build/bin/llama-server"
LOG="$REPO/logs/turboquant.log"

[[ -x "$BIN" ]] || { echo "❌ TurboQuant fork not built. Run scripts/build-llama.sh"; exit 1; }
resolve_model "$MODEL_INPUT"
MODEL="$RESOLVED_MODEL"
ensure_model "$MODEL"

# Per-model defaults for CTX / KV / RoPE. Anything already in env wins; the
# rest is filled from configs/model-defaults.env. See that file for guidance
# on adding a new alias or extending ctx past n_ctx_train via YaRN.
load_model_defaults "$MODEL_INPUT"
CTX="${CTX:-131072}"
KV="${KV:-turbo3}"   # turbo2 / turbo3 / turbo4 / q8_0 / q4_0 / f16

ensure_port_free "$PORT"
mkdir -p "$REPO/logs"

# Probe the binary for the requested cache type.
# Note: we capture help into a variable first — `cmd | grep -q` closes stdin
# after the first match, the binary gets SIGPIPE on its next write, and with
# `set -o pipefail` that turns into a false "not found" verdict.
HELP_OUT=$("$BIN" -h 2>&1 || true)
if ! grep -q -- "$KV" <<< "$HELP_OUT"; then
  echo "⚠  '$KV' not in this build's --cache-type help."
  echo "   Available cache types in this build:"
  grep -A2 -i "cache.type" <<< "$HELP_OUT" | head -10
  echo "   Falling back to KV=q8_0"
  KV=q8_0
fi

# Optional YaRN RoPE flags. Empty array if no scaling requested.
# shellcheck disable=SC2207
ROPE_FLAGS=( $(rope_args) )

ROPE_DESC=""
[[ -n "${ROPE_SCALING:-}" ]] && ROPE_DESC=" rope=${ROPE_SCALING}@${ROPE_SCALE:-1.0}x(orig=${YARN_ORIG_CTX:-?})"

echo "▶ turboquant @ http://127.0.0.1:$PORT  (KV=$KV, ${CTX} ctx${ROPE_DESC})"
echo "  TURBO_LAYER_ADAPTIVE=1   log → $LOG"
if (( DRY_RUN )); then
  printf "dry-run:"
  printf " %q" TURBO_LAYER_ADAPTIVE=1 exec "$BIN" \
    -m "$MODEL" \
    --port "$PORT" \
    -c "$CTX" \
    -ctk "$KV" -ctv "$KV" \
    "${COMMON[@]}" \
    "${SAMPLING[@]}" \
    "${ROPE_FLAGS[@]}" \
    --alias qwen3.6-turboquant
  printf " 2>&1 | tee %q\n" "$LOG"
  exit 0
fi

TURBO_LAYER_ADAPTIVE=1 exec "$BIN" \
  -m "$MODEL" \
  --port "$PORT" \
  -c "$CTX" \
  -ctk "$KV" -ctv "$KV" \
  "${COMMON[@]}" \
  "${SAMPLING[@]}" \
  "${ROPE_FLAGS[@]}" \
  --alias qwen3.6-turboquant \
  2>&1 | tee "$LOG"
