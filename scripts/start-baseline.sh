#!/usr/bin/env bash
# Start the same Qwen3.8 model on mainline llama.cpp for controlled comparison.
# Vision, reasoning, metrics, and agent tools remain enabled; only TurboQuant
# KV and embedded MTP are removed so benchmark deltas have one clear cause.
#
# Modes:
#   (default)            Foreground. The recommended comparison mode: the
#                        baseline is meant to run side-by-side with a benchmark
#                        session, and it dies with the terminal by design.
#   background           Nohup + disown into logs/qwen38-baseline.log, then a
#                        bounded health wait. The whole subshell's fds are
#                        detached the same way proxy.sh does it, so the caller
#                        is never blocked by the server's lifetime.
#                        Usage: start-baseline.sh background [port] [ctx]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${PORT:=${PORT_BASELINE:-10500}}"
: "${CTX:=32768}"
source "$SCRIPT_DIR/_common.sh"

MODE="foreground"
case "${1:-}" in
  -h|--help) print_help_from_header; exit 0 ;;
  --dry-run) DRY_RUN=1 ;;
  background) MODE="background"; DRY_RUN=0 ;;
  "") DRY_RUN=0 ;;
  *) die "unknown argument: $1 (modes: background, --dry-run)" ;;
esac

if [[ "$MODE" == "background" ]]; then
  # Optional overrides come AFTER the mode word so they never collide with
  # the argument parser: ./scripts/start-baseline.sh background 10500 32768
  : "${2:=${PORT_BASELINE:-10500}}"
  : "${3:=${CTX:-32768}}"
  export PORT="$2" CTX="$3"
fi

# Baseline runs on its own port + smaller context than the turboquant primary.
: "${PORT:=10500}"
: "${CTX:=32768}"

if [[ "$MODE" == "background" ]]; then
  # Skip the single-server guard: a backgrounded baseline is intended to run
  # ALONGSIDE the turboquant primary (that's what a parallel benchmark needs).
  export ALLOW_STACK=1
fi

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

if [[ "$MODE" == "background" ]]; then
  ensure_port_free "$PORT"
  mkdir -p "$REPO/logs"
  # Detach exactly like proxy.sh start: redirect the subshell's own
  # stdout/stderr to /dev/null (nohup covers only the child's fds), else the
  # caller's pipe stays open for the server's whole lifetime.
  ( cd "$REPO" && nohup env "${CMD[@]}" >> "$LOG" 2>&1 & disown ) >/dev/null 2>&1
  if wait_for_health "$PORT" 180; then
    echo "baseline started on :$PORT; log -> ${LOG#"$REPO"/}"
    exit 0
  fi
  echo "baseline failed to become healthy on :$PORT within 180 s; check ${LOG#"$REPO"/}" >&2
  exit 1
fi

ensure_no_other_llama_server
ensure_port_free "$PORT"
preflight_memory
mkdir -p "$REPO/logs"

log_banner "Starting Qwen3.8 mainline baseline on http://127.0.0.1:$PORT" | tee -a "$LOG"
{
  echo "  context=$CTX kv=f16/f16 mtp=off vision=on agent=$AGENT"
  echo "  log=$LOG"
} | timestamp_logs | tee -a "$LOG"
exec "${CMD[@]}" 2>&1 | timestamp_logs | tee -a "$LOG"
