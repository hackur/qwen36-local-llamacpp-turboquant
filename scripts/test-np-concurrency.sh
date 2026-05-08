#!/usr/bin/env bash
# test-np-concurrency.sh — `-np 2` concurrent slots test (#47).
#
# Re-launches the primary alias on a transient port with `-np 2`, then runs
# two parallel scripts/bench.py invocations against it (background + wait)
# and compares aggregate throughput against the single-slot baseline numbers
# captured in benchmarks/RESULTS.md (2026-05-07 entry).
#
# Usage:
#   ./scripts/test-np-concurrency.sh                   # qwen36-neo on :10597
#   MODEL=qwen36-35b PORT=10596 ./scripts/test-np-concurrency.sh
#
# Explicitly does NOT touch the launchd-managed primary on :10501.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

case "${1:-}" in -h|--help) print_help_from_header; exit 0 ;; esac

MODEL_INPUT="${MODEL:-qwen36-neo}"
PORT="${PORT:-10597}"
BIN="$REPO/vendor/llama-cpp-turboquant/build/bin/llama-server"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO/benchmarks/np-concurrency-${TS}.md"
LOG="$REPO/logs/np-concurrency-${TS}.log"

[[ -x "$BIN" ]] || { echo "TurboQuant fork not built. Run scripts/build-llama.sh"; exit 1; }
[[ "$PORT" == "10501" ]] && { echo "refusing to use primary port :10501 — pass PORT=<other>"; exit 1; }

resolve_model "$MODEL_INPUT"
MODEL_PATH="$RESOLVED_MODEL"
ensure_model "$MODEL_PATH"
load_model_defaults "$MODEL_INPUT"
CTX="${CTX:-131072}"
KV="${KV:-turbo3}"
apply_kv_split

mkdir -p "$REPO/benchmarks" "$REPO/logs"
ensure_port_free "$PORT"

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

# Override COMMON's `-np 1` with `-np 2`. We rebuild it explicitly rather than
# mutating the shared array — keeps the override visible at the call site.
COMMON_NP2=()
for a in "${COMMON[@]}"; do
  if [[ "$a" == "1" && "${prev:-}" == "-np" ]]; then a=2; fi
  COMMON_NP2+=("$a")
  prev="$a"
done

echo "── launching ${MODEL_INPUT} on :${PORT} with -np 2 ──"
TURBO_LAYER_ADAPTIVE=1 "$BIN" \
  -m "$MODEL_PATH" \
  --port "$PORT" \
  -c "$CTX" \
  -ctk "$KV_K" -ctv "$KV_V" \
  "${COMMON_NP2[@]}" \
  "${SAMPLING[@]}" \
  --alias qwen3.6-np2 \
  > "$LOG" 2>&1 &
SERVER_PID=$!

if ! wait_for_health "$PORT"; then
  echo "health timeout — see $LOG"
  exit 1
fi

CLIENT_A_OUT="$REPO/logs/np-concurrency-${TS}-clientA.txt"
CLIENT_B_OUT="$REPO/logs/np-concurrency-${TS}-clientB.txt"

T0=$(date +%s)
python3 "$SCRIPT_DIR/bench.py" "$PORT" "clientA" > "$CLIENT_A_OUT" 2>&1 &
PA=$!
python3 "$SCRIPT_DIR/bench.py" "$PORT" "clientB" > "$CLIENT_B_OUT" 2>&1 &
PB=$!
wait "$PA"; RA=$?
wait "$PB"; RB=$?
T1=$(date +%s)
WALL=$(( T1 - T0 ))

GEN_A=$(awk '/avg gen:/ {print $3; exit}' "$CLIENT_A_OUT")
GEN_B=$(awk '/avg gen:/ {print $3; exit}' "$CLIENT_B_OUT")
PROMPT_A=$(awk '/avg prompt:/ {print $7; exit}' "$CLIENT_A_OUT")
PROMPT_B=$(awk '/avg prompt:/ {print $7; exit}' "$CLIENT_B_OUT")
: "${GEN_A:=?}" "${GEN_B:=?}" "${PROMPT_A:=?}" "${PROMPT_B:=?}"

# Aggregate gen tok/s — sum the two arms (each generated 3×500 tokens
# concurrently against the same server).
AGG=$(awk -v a="$GEN_A" -v b="$GEN_B" 'BEGIN{ if (a+0>0 && b+0>0) printf "%.2f", a+b; else print "?"}')

cleanup; SERVER_PID=""

{
  echo "# -np 2 concurrency test — ${MODEL_INPUT}"
  echo
  echo "Run: ${TS}  port: ${PORT}  CTX: ${CTX}  KV: ${KV_K}/${KV_V}  wall: ${WALL}s"
  echo "Client exits: A=${RA} B=${RB}"
  echo
  echo "| Slot | Gen tok/s | Prompt tok/s |"
  echo "|---|---:|---:|"
  echo "| client A | ${GEN_A} | ${PROMPT_A} |"
  echo "| client B | ${GEN_B} | ${PROMPT_B} |"
  echo "| **aggregate** | **${AGG}** | — |"
  echo
  echo "## Compare against single-slot baseline"
  echo
  echo "See \`benchmarks/RESULTS.md\` 2026-05-07 entry for the live :10501"
  echo "single-slot numbers (qwen36-neo turbo3 @ 131K, 3-run avg)."
  echo "If aggregate gen tok/s is roughly equal to the single-slot number,"
  echo "the two slots are sharing the same compute — there's no parallelism"
  echo "win, only latency hiding. If aggregate exceeds it, we're getting"
  echo "real concurrency."
  echo
  echo "Raw client logs: \`$(basename "$CLIENT_A_OUT")\`, \`$(basename "$CLIENT_B_OUT")\`"
  echo "Server log: \`$(basename "$LOG")\`"
} > "$OUT"

echo
echo "wrote $OUT"
