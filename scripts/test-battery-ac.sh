#!/usr/bin/env bash
# test-battery-ac.sh — battery vs AC sustained-load bench (#46).
#
# Captures comparable bench numbers across a power-state transition. Runs
# scripts/bench.py RUNS times on the current power source, prompts the user
# to flip the cable (unplug or plug in), waits for the system to settle, and
# repeats. Output is a side-by-side report so we can quantify how much (if
# any) the M3 Max throttles inference under battery vs AC. See
# benchmarks/RESULTS.md (2026-05-07 entry) for the single-slot baseline this
# is comparing against.
#
# Usage:
#   ./scripts/test-battery-ac.sh                  # qwen36-neo on :10595, 3 runs
#   MODEL=qwen36-35b RUNS=5 ./scripts/test-battery-ac.sh
#
# Explicitly does NOT touch the launchd-managed primary on :10501.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

case "${1:-}" in -h|--help) print_help_from_header; exit 0 ;; esac

MODEL_INPUT="${MODEL:-qwen36-neo}"
PORT="${PORT:-10595}"
RUNS="${RUNS:-3}"
SETTLE="${SETTLE:-75}"      # 60-90s settle window after the manual switch
COOLDOWN="${COOLDOWN:-60}"  # cool-down between arms (in addition to manual prompt)
BIN="$REPO/vendor/llama-cpp-turboquant/build/bin/llama-server"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO/benchmarks/battery-ac-${TS}.md"

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

# Power-state probes. `pmset -g batt` first line is "Now drawing from
# 'AC Power'" or "'Battery Power'".
power_source() {
  pmset -g batt 2>/dev/null | grep -iE 'AC Power|Battery Power' | head -1
}
power_ps() {
  pmset -g ps 2>/dev/null | head -3
}

# run_arm <label> — launch, RUNS× bench.py, capture per-run gen tok/s into
# $REPO/logs/battery-ac-${TS}-${label}.runs (one number per line).
run_arm() {
  local label="$1"
  local log="$REPO/logs/battery-ac-${TS}-${label}.log"
  local runs_file="$REPO/logs/battery-ac-${TS}-${label}.runs"
  local prompts_file="$REPO/logs/battery-ac-${TS}-${label}.prompts"
  : > "$runs_file"; : > "$prompts_file"

  ensure_port_free "$PORT"
  echo "── arm: ${label} — launching ${MODEL_INPUT} on :${PORT} ──"
  TURBO_LAYER_ADAPTIVE=1 "$BIN" \
    -m "$MODEL_PATH" \
    --port "$PORT" \
    -c "$CTX" \
    -ctk "$KV_K" -ctv "$KV_V" \
    "${COMMON[@]}" \
    "${SAMPLING[@]}" \
    --alias "qwen3.6-batt-${label}" \
    > "$log" 2>&1 &
  SERVER_PID=$!

  if ! wait_for_health "$PORT"; then
    echo "  health timeout — see $log"
    cleanup; SERVER_PID=""
    return 1
  fi

  local i
  for i in $(seq 1 "$RUNS"); do
    echo "  bench ${i}/${RUNS} (${label})"
    local out
    out="$(python3 "$SCRIPT_DIR/bench.py" "$PORT" "${label}-${i}" 2>&1 || true)"
    printf "%s\n" "$out" >> "${log}.bench"
    local gen prompt
    gen=$(printf "%s\n" "$out"    | awk '/avg gen:/ {print $3; exit}')
    prompt=$(printf "%s\n" "$out" | awk '/avg prompt:/ {print $7; exit}')
    : "${gen:=?}" "${prompt:=?}"
    echo "$gen"    >> "$runs_file"
    echo "$prompt" >> "$prompts_file"
  done

  cleanup; SERVER_PID=""
}

# stats <file> — emits "mean stddev" for the numeric column in <file>; "?" for
# both if any value is missing. Two-pass awk keeps this readable.
stats() {
  awk '
    { if ($1 == "?" || $1 == "") { bad=1; next }
      n++; s+=$1; xs[n]=$1 }
    END {
      if (bad || n==0) { print "? ?"; exit }
      m=s/n; ss=0
      for (i=1;i<=n;i++){ d=xs[i]-m; ss+=d*d }
      sd=(n>1)?sqrt(ss/(n-1)):0
      printf "%.2f %.2f\n", m, sd
    }
  ' "$1"
}

# ── start ───────────────────────────────────────────────────────────────────
PS_INITIAL="$(power_source)"
PS_INITIAL_FULL="$(power_ps)"
echo "initial power source: ${PS_INITIAL}"

case "$PS_INITIAL" in
  *AC*)      ARM1_LABEL="ac";      ARM2_LABEL="battery"; SWITCH_VERB="UNPLUG" ;;
  *Battery*) ARM1_LABEL="battery"; ARM2_LABEL="ac";      SWITCH_VERB="PLUG IN" ;;
  *) echo "❌ couldn't parse power source from pmset: '$PS_INITIAL'"; exit 1 ;;
esac

"$SCRIPT_DIR/diagnose-variance.sh" --tag "battery-ac-${TS}-${ARM1_LABEL}-pre"  >/dev/null || true
run_arm "$ARM1_LABEL" || { echo "❌ arm 1 (${ARM1_LABEL}) failed"; exit 1; }
"$SCRIPT_DIR/diagnose-variance.sh" --tag "battery-ac-${TS}-${ARM1_LABEL}-post" >/dev/null || true

# ── manual switch ───────────────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════════════════"
echo "  ${SWITCH_VERB} NOW (current: ${PS_INITIAL})"
echo "  Press ENTER to continue once the cable is switched."
echo "════════════════════════════════════════════════════════════════════"
read -r _ || true

PS_AFTER="$(power_source)"
echo "post-switch power source: ${PS_AFTER}"
if [[ "$PS_AFTER" == "$PS_INITIAL" ]]; then
  echo "❌ power source unchanged — refusing to run arm 2."
  echo "   Did you flip the cable? Got: '$PS_AFTER'"
  exit 1
fi

echo "  settle ${SETTLE}s so the system catches up to the power state change…"
sleep "$SETTLE"

if (( COOLDOWN > 0 )); then
  echo "  cool-down ${COOLDOWN}s between arms…"
  sleep "$COOLDOWN"
fi

PS_FINAL_FULL="$(power_ps)"

"$SCRIPT_DIR/diagnose-variance.sh" --tag "battery-ac-${TS}-${ARM2_LABEL}-pre"  >/dev/null || true
run_arm "$ARM2_LABEL" || { echo "❌ arm 2 (${ARM2_LABEL}) failed"; exit 1; }
"$SCRIPT_DIR/diagnose-variance.sh" --tag "battery-ac-${TS}-${ARM2_LABEL}-post" >/dev/null || true

# ── report ──────────────────────────────────────────────────────────────────
ARM1_RUNS="$REPO/logs/battery-ac-${TS}-${ARM1_LABEL}.runs"
ARM2_RUNS="$REPO/logs/battery-ac-${TS}-${ARM2_LABEL}.runs"
ARM1_PROMPTS="$REPO/logs/battery-ac-${TS}-${ARM1_LABEL}.prompts"
ARM2_PROMPTS="$REPO/logs/battery-ac-${TS}-${ARM2_LABEL}.prompts"

read -r ARM1_MEAN ARM1_SD < <(stats "$ARM1_RUNS")
read -r ARM2_MEAN ARM2_SD < <(stats "$ARM2_RUNS")
read -r ARM1_PMEAN ARM1_PSD < <(stats "$ARM1_PROMPTS")
read -r ARM2_PMEAN ARM2_PSD < <(stats "$ARM2_PROMPTS")

# Throttle ratio = (AC mean - battery mean) / AC mean × 100. Always express as
# "battery throttled X% vs AC" regardless of which arm ran first.
AC_MEAN="$ARM1_MEAN"; BATT_MEAN="$ARM2_MEAN"
if [[ "$ARM1_LABEL" == "battery" ]]; then AC_MEAN="$ARM2_MEAN"; BATT_MEAN="$ARM1_MEAN"; fi
THROTTLE=$(awk -v a="$AC_MEAN" -v b="$BATT_MEAN" 'BEGIN{
  if (a+0>0 && b+0>0) printf "%.1f", (a-b)/a*100; else print "?"
}')

{
  echo "# Battery vs AC sustained-load bench — ${MODEL_INPUT}"
  echo
  echo "Run: ${TS}  port: ${PORT}  CTX: ${CTX}  KV: ${KV_K}/${KV_V}  RUNS/arm: ${RUNS}"
  echo "Arm order: 1=${ARM1_LABEL}, 2=${ARM2_LABEL}"
  echo
  echo "## Power state"
  echo
  echo '```'
  echo "before arm 1 (${ARM1_LABEL}):"
  echo "$PS_INITIAL_FULL"
  echo
  echo "before arm 2 (${ARM2_LABEL}):"
  echo "$PS_FINAL_FULL"
  echo '```'
  echo
  echo "## Per-run gen tok/s"
  echo
  printf "| run |"
  for i in $(seq 1 "$RUNS"); do printf " %d |" "$i"; done
  echo " mean ± stddev |"
  printf "|---|"
  for i in $(seq 1 "$RUNS"); do printf "---:|"; done
  echo "---:|"
  printf "| %s |" "$ARM1_LABEL"
  while read -r v; do printf " %s |" "$v"; done < "$ARM1_RUNS"
  printf " %s ± %s |\n" "$ARM1_MEAN" "$ARM1_SD"
  printf "| %s |" "$ARM2_LABEL"
  while read -r v; do printf " %s |" "$v"; done < "$ARM2_RUNS"
  printf " %s ± %s |\n" "$ARM2_MEAN" "$ARM2_SD"
  echo
  echo "## Per-run prompt tok/s"
  echo
  printf "| run |"
  for i in $(seq 1 "$RUNS"); do printf " %d |" "$i"; done
  echo " mean ± stddev |"
  printf "|---|"
  for i in $(seq 1 "$RUNS"); do printf "---:|"; done
  echo "---:|"
  printf "| %s |" "$ARM1_LABEL"
  while read -r v; do printf " %s |" "$v"; done < "$ARM1_PROMPTS"
  printf " %s ± %s |\n" "$ARM1_PMEAN" "$ARM1_PSD"
  printf "| %s |" "$ARM2_LABEL"
  while read -r v; do printf " %s |" "$v"; done < "$ARM2_PROMPTS"
  printf " %s ± %s |\n" "$ARM2_PMEAN" "$ARM2_PSD"
  echo
  echo "## Conclusion"
  echo
  if [[ "$THROTTLE" == "?" ]]; then
    echo "Throttle ratio could not be computed (one arm reported '?'). Inspect"
    echo "the per-arm bench logs in \`logs/\` for failures."
  else
    echo "Battery throttled **${THROTTLE}%** vs AC on gen tok/s"
    echo "(AC mean ${AC_MEAN} vs battery mean ${BATT_MEAN}). Variance bands"
    echo "(stddev columns above) should be narrower than the AC↔battery"
    echo "delta — if they overlap, the throttle effect is within noise and"
    echo "this run isn't conclusive."
  fi
  echo
  echo "Raw bench output: per-arm \`logs/battery-ac-${TS}-*.log.bench\`."
  echo "Variance snapshots: \`logs/variance-*-battery-ac-${TS}-*\`."
} > "$OUT"

echo
echo "wrote $OUT"
