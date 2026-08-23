#!/usr/bin/env bash
# Start the complete Qwen3.8 runtime on port 10501.
#
# Enabled by default: Q8_0 weights, q8_0/turbo3 KV, native 262K context,
# adaptive chained MTP, the BF16 vision projector, preserved reasoning,
# Prometheus metrics, WebUI MCP proxy, and all llama.cpp built-in agent tools.
# Use environment overrides from configs/runtime.env only for controlled tests.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

case "${1:-}" in
  -h|--help) print_help_from_header; exit 0 ;;
  --dry-run) DRY_RUN=1 ;;
  "") DRY_RUN=0 ;;
  *) die "unknown argument: $1" ;;
esac

ensure_executable "$TURBOQUANT_BIN" "run: make build"
ensure_artifacts
HELP_OUT="$(server_help "$TURBOQUANT_BIN")"
require_help_flag "$HELP_OUT" "turbo3"
append_runtime_features "$HELP_OUT" full
RUNTIME_FLAGS+=(--cache-type-k "$KV_K" --cache-type-v "$KV_V")

LOG="$REPO/logs/qwen38.log"
CMD=(env TURBO_LAYER_ADAPTIVE=1 "$TURBOQUANT_BIN" "${RUNTIME_FLAGS[@]}")

if (( DRY_RUN )); then
  print_command "${CMD[@]}"
  exit 0
fi

ensure_no_other_llama_server
ensure_port_free "$PORT"
preflight_memory
mkdir -p "$REPO/logs"

echo "Starting Qwen3.8 full runtime on http://127.0.0.1:$PORT"
echo "  model=$MODEL_FILE"
echo "  context=$CTX kv=$KV_K/$KV_V mtp=$MTP_TYPE:$MTP_MIN-$MTP_MAX chain=$MTP_CHAIN"
echo "  vision=on reasoning-preserve=$REASONING_PRESERVE metrics=$METRICS agent=$AGENT"
echo "  log=$LOG"
exec "${CMD[@]}" 2>&1 | tee "$LOG"
