#!/usr/bin/env bash
# Start Qwen3.6-27B-MTP on the *mainline* llama-server (port 10502).
#
# Why mainline, not TurboQuant: MTP speculative-decode requires
# `--spec-type draft-mtp`, which the TurboQuant fork doesn't expose yet
# (it carries an older `--spec-type` enum: ngram-cache/ngram-simple/...).
# When TurboQuant catches up we can fold this back into start-turboquant.sh.
#
# MTP gives ~1.5–2× generation throughput on Qwen3.6 by using the model's
# own multi-token-prediction heads as a draft (no separate draft model).
#
# Upstream caveats (unsloth README, Qwen3.6 MTP guide):
#   • -np must be 1
#   • --mmproj is not yet supported alongside MTP — text-only here
#   • -fa on is required
#
# Chat template: uses froggeric/Qwen-Fixed-Chat-Templates (v19), which patches
# the stock template's tool-call XML parsing and empty-think poisoning bugs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

case "${1:-}" in -h|--help) print_help_from_header; exit 0 ;; esac

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
fi

PORT="${PORT:-10502}"
MODEL_INPUT="${MODEL:-qwen36-mtp}"
BIN="$REPO/vendor/llama.cpp-mainline/build/bin/llama-server"
LOG="$REPO/logs/qwen36-mtp.log"

[[ -x "$BIN" ]] || { echo "❌ Mainline llama-server not built. Run scripts/build-llama.sh"; exit 1; }

resolve_model "$MODEL_INPUT"
MODEL="$RESOLVED_MODEL"
ensure_model "$MODEL"

load_model_defaults "$MODEL_INPUT"
CTX="${CTX:-131072}"
KV="${KV:-q8_0}"

# MTP tuning. Conservative defaults — unsloth recommends n_max=2 for the 27B.
SPEC_N_MAX="${SPEC_N_MAX:-2}"

if (( ! DRY_RUN )); then
  ensure_no_other_llama_server
  ensure_port_free "$PORT"
fi
mkdir -p "$REPO/logs"

# Verify the binary supports draft-mtp before launching.
HELP_OUT=$("$BIN" -h 2>&1 || true)
if ! grep -q "draft-mtp" <<< "$HELP_OUT"; then
  echo "❌ This llama-server build does not list 'draft-mtp' in --spec-type." >&2
  echo "   Rebuild mainline (vendor/llama.cpp-mainline) at a SHA >= PR #22673." >&2
  exit 1
fi

apply_kv_split
# shellcheck disable=SC2207
ROPE_FLAGS=( $(rope_args) )
# shellcheck disable=SC2207
TEMPLATE_FLAGS=( $(chat_template_flags "$MODEL_INPUT") )
# shellcheck disable=SC2207
MCP_FLAGS=( $(mcp_proxy_flag "$BIN") )

METRICS_FLAGS=()
if [[ "${METRICS:-0}" == "1" || "${METRICS:-0}" == "true" ]]; then
  METRICS_FLAGS=(--metrics)
fi

# Strip --jinja from $COMMON (we override the template with -t / --chat-template-file),
# strip -np from $COMMON path safely; we pin -np 1 explicitly per MTP requirement.
echo "▶ qwen36-mtp @ http://127.0.0.1:$PORT  (mainline, KV=$KV_K/$KV_V, ${CTX} ctx, MTP n_max=$SPEC_N_MAX)"
echo "  log → $LOG"

CMD=(
  "$BIN"
  -m "$MODEL"
  --port "$PORT"
  --host 127.0.0.1
  -c "$CTX"
  -ctk "$KV_K" -ctv "$KV_V"
  -ngl 99
  -fa on
  -np 1
  --jinja
  --spec-type draft-mtp
  --spec-draft-n-max "$SPEC_N_MAX"
  --alias qwen3.6-mtp
)
CMD+=( "${SAMPLING[@]}" )
[[ ${#ROPE_FLAGS[@]}     -gt 0 ]] && CMD+=( "${ROPE_FLAGS[@]}" )
[[ ${#TEMPLATE_FLAGS[@]} -gt 0 ]] && CMD+=( "${TEMPLATE_FLAGS[@]}" )
[[ ${#MCP_FLAGS[@]}      -gt 0 ]] && CMD+=( "${MCP_FLAGS[@]}" )
[[ ${#METRICS_FLAGS[@]}  -gt 0 ]] && CMD+=( "${METRICS_FLAGS[@]}" )

if (( DRY_RUN )); then
  printf "dry-run:"
  printf " %q" "${CMD[@]}"
  printf " 2>&1 | tee %q\n" "$LOG"
  exit 0
fi

exec "${CMD[@]}" 2>&1 | tee "$LOG"
