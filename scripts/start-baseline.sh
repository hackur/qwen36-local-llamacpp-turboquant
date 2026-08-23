#!/usr/bin/env bash
# Start the same Qwen3.8 model on mainline llama.cpp for controlled comparison.
# Vision, reasoning, metrics, and agent tools remain enabled; only TurboQuant
# KV and embedded MTP are removed so benchmark deltas have one clear cause.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${PORT:=10500}"
: "${CTX:=32768}"
source "$SCRIPT_DIR/_common.sh"

case "${1:-}" in
  -h|--help) print_help_from_header; exit 0 ;;
  --dry-run) DRY_RUN=1 ;;
  "") DRY_RUN=0 ;;
  *) die "unknown argument: $1" ;;
esac

ensure_executable "$MAINLINE_BIN" "run: make build"
ensure_artifacts
HELP_OUT="$(server_help "$MAINLINE_BIN")"
append_runtime_features "$HELP_OUT" baseline
RUNTIME_FLAGS+=(--cache-type-k f16 --cache-type-v f16)

LOG="$REPO/logs/qwen38-baseline.log"
CMD=("$MAINLINE_BIN" "${RUNTIME_FLAGS[@]}")

if (( DRY_RUN )); then
  print_command "${CMD[@]}"
  exit 0
fi

ensure_no_other_llama_server
ensure_port_free "$PORT"
preflight_memory
mkdir -p "$REPO/logs"

echo "Starting Qwen3.8 mainline baseline on http://127.0.0.1:$PORT"
echo "  context=$CTX kv=f16/f16 mtp=off vision=on agent=$AGENT"
echo "  log=$LOG"
exec "${CMD[@]}" 2>&1 | tee "$LOG"
