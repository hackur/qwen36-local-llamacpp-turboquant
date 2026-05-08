#!/usr/bin/env bash
# sweep-ctx-batch.sh — automated CTX × batch-size sweep (#44).
#
# For each (CTX, BATCH) cell: launch llama-server on a transient port, wait
# for /health, run scripts/bench.py once, capture timings, tear down. Sleeps
# between cells so the chassis stays cool — see benchmarks/RESULTS.md
# (2026-05-07 entry) for why sustained 3-run benches throttle on M3 Max.
#
# Usage:
#   ./scripts/sweep-ctx-batch.sh                       # qwen36-neo on :10599
#   MODEL=qwen36-35b ./scripts/sweep-ctx-batch.sh
#   ./scripts/sweep-ctx-batch.sh --no-cooldown         # skip 60s sleeps
#
# Explicitly does NOT touch the launchd-managed primary on :10501.
# Output: benchmarks/sweep-<ts>.md, appended row-by-row so partial results
# survive a kill. Pre/post variance snapshots wrap the whole sweep.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

COOLDOWN=60
if [[ "${1:-}" == "--no-cooldown" ]]; then
  COOLDOWN=0
  shift || true
fi

MODEL_INPUT="${MODEL:-qwen36-neo}"
PORT="${PORT:-10599}"
BIN="$REPO/vendor/llama-cpp-turboquant/build/bin/llama-server"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO/benchmarks/sweep-${TS}.md"

CTX_GRID=(${CTX_GRID:-32768 65536 131072 262144})
BATCH_GRID=(${BATCH_GRID:-512 1024 2048 4096})

[[ -x "$BIN" ]] || { echo "TurboQuant fork not built. Run scripts/build-llama.sh"; exit 1; }
[[ "$PORT" == "10501" ]] && { echo "refusing to use primary port :10501 — pass PORT=<other>"; exit 1; }

resolve_model "$MODEL_INPUT"
MODEL_PATH="$RESOLVED_MODEL"
ensure_model "$MODEL_PATH"
load_model_defaults "$MODEL_INPUT"
KV="${KV:-turbo3}"
apply_kv_split

mkdir -p "$REPO/benchmarks" "$REPO/logs"

# Pre-snapshot
"$SCRIPT_DIR/diagnose-variance.sh" --tag "sweep-${TS}-pre" || true

{
  echo "# CTX × batch-size sweep — ${MODEL_INPUT}"
  echo
  echo "Run: ${TS}  port: ${PORT}  KV: ${KV_K}/${KV_V}  cooldown: ${COOLDOWN}s"
  echo
  echo "| CTX | -b | gen tok/s | prompt tok/s | wall (s) | notes |"
  echo "|----:|---:|----------:|-------------:|---------:|:------|"
} > "$OUT"

cleanup() {
  local pid="${SERVER_PID:-}"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 2
    kill -9 "$pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

wait_for_health() {
  local port="$1" tries=60
  while (( tries-- > 0 )); do
    if curl -sf "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}

CELL=0
TOTAL=$(( ${#CTX_GRID[@]} * ${#BATCH_GRID[@]} ))
for ctx in "${CTX_GRID[@]}"; do
  for batch in "${BATCH_GRID[@]}"; do
    CELL=$(( CELL + 1 ))
    echo "── [${CELL}/${TOTAL}] ctx=${ctx} batch=${batch} ──"
    ensure_port_free "$PORT"
    LOG="$REPO/logs/sweep-${TS}-c${ctx}-b${batch}.log"

    TURBO_LAYER_ADAPTIVE=1 "$BIN" \
      -m "$MODEL_PATH" \
      --port "$PORT" \
      -c "$ctx" \
      -b "$batch" \
      -ctk "$KV_K" -ctv "$KV_V" \
      "${COMMON[@]}" \
      "${SAMPLING[@]}" \
      --alias qwen3.6-sweep \
      > "$LOG" 2>&1 &
    SERVER_PID=$!

    if ! wait_for_health "$PORT"; then
      echo "| ${ctx} | ${batch} | — | — | — | health timeout (see $(basename "$LOG")) |" >> "$OUT"
      cleanup; SERVER_PID=""
      [[ "$COOLDOWN" -gt 0 ]] && sleep "$COOLDOWN"
      continue
    fi

    BENCH_OUT="$(python3 "$SCRIPT_DIR/bench.py" "$PORT" "ctx${ctx}-b${batch}" 2>&1 || true)"
    GEN_AVG=$(printf "%s\n" "$BENCH_OUT" | awk '/avg gen:/ {print $3; exit}')
    PROMPT_AVG=$(printf "%s\n" "$BENCH_OUT" | awk '/avg prompt:/ {print $7; exit}')
    WALL=$(printf "%s\n" "$BENCH_OUT" | awk -F'wall=' '/run 1:/ {print $2; exit}' | tr -d 's')
    : "${GEN_AVG:=?}" "${PROMPT_AVG:=?}" "${WALL:=?}"

    echo "| ${ctx} | ${batch} | ${GEN_AVG} | ${PROMPT_AVG} | ${WALL} | log:$(basename "$LOG") |" >> "$OUT"
    cleanup; SERVER_PID=""

    if (( CELL < TOTAL )) && (( COOLDOWN > 0 )); then
      echo "  cool-down ${COOLDOWN}s…"
      sleep "$COOLDOWN"
    fi
  done
done

# Post-snapshot
"$SCRIPT_DIR/diagnose-variance.sh" --tag "sweep-${TS}-post" || true

echo
echo "wrote $OUT"
