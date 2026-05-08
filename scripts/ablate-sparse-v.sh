#!/usr/bin/env bash
# ablate-sparse-v.sh — TURBO_SPARSE_V=0 ablation (#45).
#
# Launches qwen36-35b twice on a transient port: once with TURBO_SPARSE_V=1
# (default) and once with TURBO_SPARSE_V=0. Same prompt set as bench.py × 3
# runs each. Cool-down between, so the chassis doesn't get hammered (see
# benchmarks/RESULTS.md 2026-05-07 — sustained 3-run benches throttle).
#
# Quality observation is left to the user — the script captures one
# free-form generated sample per arm and a side-by-side speed table; eyeball
# the samples and fill in the "Quality observation" section after the run.
#
# Usage:
#   ./scripts/ablate-sparse-v.sh                # default qwen36-35b on :10598
#   MODEL=qwen36-neo ./scripts/ablate-sparse-v.sh
#   ./scripts/ablate-sparse-v.sh --no-cooldown  # skip 60s sleep between arms
#
# Explicitly does NOT touch the launchd-managed primary on :10501.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

COOLDOWN=60
if [[ "${1:-}" == "--no-cooldown" ]]; then
  COOLDOWN=0
  shift || true
fi

MODEL_INPUT="${MODEL:-qwen36-35b}"
PORT="${PORT:-10598}"
BIN="$REPO/vendor/llama-cpp-turboquant/build/bin/llama-server"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO/benchmarks/sparse-v-ablation-${TS}.md"

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

run_arm() {
  local sparse="$1"           # 0 or 1
  local label="$2"            # e.g. sparse_v_on
  local sample_file="$3"
  ensure_port_free "$PORT"
  local log="$REPO/logs/ablate-${TS}-${label}.log"

  echo "── arm: ${label} (TURBO_SPARSE_V=${sparse}) ──"
  TURBO_LAYER_ADAPTIVE=1 TURBO_SPARSE_V="$sparse" "$BIN" \
    -m "$MODEL_PATH" \
    --port "$PORT" \
    -c "$CTX" \
    -ctk "$KV_K" -ctv "$KV_V" \
    "${COMMON[@]}" \
    "${SAMPLING[@]}" \
    --alias "qwen3.6-ablate-${label}" \
    > "$log" 2>&1 &
  SERVER_PID=$!

  if ! wait_for_health "$PORT"; then
    echo "  health timeout — see $log"
    cleanup; SERVER_PID=""
    return 1
  fi

  python3 "$SCRIPT_DIR/bench.py" "$PORT" "$label" | tee -a "$OUT.bench.txt"

  # Capture one free-form sample so the user can eyeball quality afterwards.
  curl -s "http://127.0.0.1:${PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d '{"model":"local","messages":[{"role":"user","content":"Write a 200-word paragraph explaining why ocean tides have two daily peaks. Keep it factually correct."}],"max_tokens":400,"chat_template_kwargs":{"enable_thinking":false}}' \
    > "$sample_file" 2>&1 || true

  cleanup; SERVER_PID=""
}

extract_avg_gen() {
  awk -v lab="$1" '
    $0 ~ "=== "lab {found=1}
    found && /avg gen:/ {print $3; exit}
  ' "$OUT.bench.txt"
}

SAMPLE_ON="$REPO/benchmarks/ablate-${TS}-sparse_v_on.json"
SAMPLE_OFF="$REPO/benchmarks/ablate-${TS}-sparse_v_off.json"
: > "$OUT.bench.txt"

run_arm 1 "sparse_v_on"  "$SAMPLE_ON"
[[ "$COOLDOWN" -gt 0 ]] && { echo "  cool-down ${COOLDOWN}s…"; sleep "$COOLDOWN"; }
run_arm 0 "sparse_v_off" "$SAMPLE_OFF"

GEN_ON=$(extract_avg_gen "sparse_v_on")
GEN_OFF=$(extract_avg_gen "sparse_v_off")

{
  echo "# TURBO_SPARSE_V ablation — ${MODEL_INPUT}"
  echo
  echo "Run: ${TS}  port: ${PORT}  CTX: ${CTX}  KV: ${KV_K}/${KV_V}"
  echo
  echo "## Speed (3-run avg, 500-token gen)"
  echo
  echo "| Arm | TURBO_SPARSE_V | Gen tok/s |"
  echo "|---|:-:|---:|"
  echo "| on (default) | 1 | ${GEN_ON:-?} |"
  echo "| off          | 0 | ${GEN_OFF:-?} |"
  echo
  echo "Raw bench output: \`$(basename "$OUT.bench.txt")\`"
  echo
  echo "## Quality observation"
  echo
  echo "Samples captured (eyeball both, fill in below):"
  echo "- on:  \`$(basename "$SAMPLE_ON")\`"
  echo "- off: \`$(basename "$SAMPLE_OFF")\`"
  echo
  echo "_TODO (user): describe any quality difference — coherence, factual"
  echo "drift, token-level artifacts. Default arm is on; off is the ablation._"
} > "$OUT"

echo
echo "wrote $OUT"
