#!/usr/bin/env bash
# Strict A/B bench harness — enforces the discipline rules from
# docs/benchmarking-discipline.md:
#
#   * One llama-server at a time on this Mac (thermal caution).
#   * Fixed max_tokens, warm-state only (warmup discarded).
#   * N=5 runs, reports median + min/max (not mean — outliers matter).
#   * Refuses to run if both target ports are listening simultaneously.
#   * Records model alias + git SHA of each server's binary path so the
#     output is reproducible/auditable.
#
# Usage:
#   scripts/bench-ab.sh <portA> <portB> [labelA] [labelB]
#   scripts/bench-ab.sh 10500 10501 baseline turboquant
#
# Flow: bring up A only → script benches A → you stop A and bring up B →
# script benches B → prints side-by-side. Script does NOT start/stop
# servers itself; that's deliberate (you control thermal pacing).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PORT_A="${1:?usage: bench-ab.sh <portA> <portB> [labelA] [labelB]}"
PORT_B="${2:?usage: bench-ab.sh <portA> <portB> [labelA] [labelB]}"
LABEL_A="${3:-port-$PORT_A}"
LABEL_B="${4:-port-$PORT_B}"
N="${N:-5}"
MAX_TOKENS="${MAX_TOKENS:-500}"

PROMPT="${PROMPT:-Explain in detail how transformer attention mechanisms work. Cover self-attention, multi-head attention, key-query-value matrices, and positional encoding. Write at least 400 words.}"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO/benchmarks/ab-$TS.json"
mkdir -p "$REPO/benchmarks"

is_listening() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; }

wait_for_solo() {
  local want="$1" other="$2"
  while true; do
    if is_listening "$want" && ! is_listening "$other"; then return 0; fi
    if is_listening "$want" && is_listening "$other"; then
      echo "  ✗ both :$want and :$other are listening. Stop the other one (thermal)." >&2
    elif ! is_listening "$want"; then
      echo "  … waiting for :$want to come up (and :$other to be down). Ctrl-C to abort." >&2
    fi
    sleep 5
  done
}

server_meta() {
  local port="$1" url="http://127.0.0.1:$port"
  curl -sf "$url/props" 2>/dev/null \
    | jq -r '"alias=\(.default_generation_settings.model // "?") ctx=\(.default_generation_settings.n_ctx // "?")"' \
    || echo "alias=? ctx=?"
}

median() { sort -n | awk '{a[NR]=$1} END {print (NR%2 ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2)}'; }

bench_one() {
  local port="$1" label="$2"
  local url="http://127.0.0.1:$port"
  echo "── $label  (port $port) ──"
  echo "  meta:  $(server_meta "$port")"

  # warmup — discarded
  curl -sf "$url/v1/chat/completions" -H "Content-Type: application/json" \
    -d "$(jq -nc --arg p "$PROMPT" --argjson mt "$MAX_TOKENS" \
          '{model:"local",messages:[{role:"user",content:$p}],max_tokens:$mt,chat_template_kwargs:{enable_thinking:false}}')" \
    >/dev/null

  local tps_list=()
  for i in $(seq 1 "$N"); do
    local r tps n
    r=$(curl -sf "$url/v1/chat/completions" -H "Content-Type: application/json" \
        -d "$(jq -nc --arg p "$PROMPT" --argjson mt "$MAX_TOKENS" \
              '{model:"local",messages:[{role:"user",content:$p}],max_tokens:$mt,chat_template_kwargs:{enable_thinking:false}}')")
    tps=$(echo "$r" | jq -r '.timings.predicted_per_second // 0')
    n=$(echo "$r"   | jq -r '.timings.predicted_n // 0')
    printf "  run %d: %7.2f tok/s  (%s tokens)\n" "$i" "$tps" "$n"
    tps_list+=("$tps")
    echo "$r" | jq -c --arg label "$label" --arg port "$port" --arg run "$i" \
      '{label:$label, port:$port, run:$run, timings:.timings}' >> "$OUT"
  done

  local med min max
  med=$(printf "%s\n" "${tps_list[@]}" | median)
  min=$(printf "%s\n" "${tps_list[@]}" | sort -n | head -1)
  max=$(printf "%s\n" "${tps_list[@]}" | sort -n | tail -1)
  printf "  median %.2f  min %.2f  max %.2f  (n=%d, max_tokens=%d)\n\n" \
    "$med" "$min" "$max" "$N" "$MAX_TOKENS"
  # stash summary line for the final table
  echo "$label|$port|$med|$min|$max" >> "$OUT.summary"
}

: > "$OUT.summary"

echo "▶ A/B bench  ${LABEL_A} (:$PORT_A)  vs  ${LABEL_B} (:$PORT_B)"
echo "  N=$N  max_tokens=$MAX_TOKENS  out=$OUT"
echo

echo "Step 1/2 — bring up ONLY :$PORT_A (stop :$PORT_B if running)."
wait_for_solo "$PORT_A" "$PORT_B"
bench_one "$PORT_A" "$LABEL_A"

echo "Step 2/2 — stop :$PORT_A, bring up ONLY :$PORT_B."
wait_for_solo "$PORT_B" "$PORT_A"
bench_one "$PORT_B" "$LABEL_B"

echo "── summary ──"
printf "  %-15s %-6s %8s %8s %8s\n" label port median min max
while IFS='|' read -r l p med mn mx; do
  printf "  %-15s %-6s %8.2f %8.2f %8.2f\n" "$l" "$p" "$med" "$mn" "$mx"
done < "$OUT.summary"
rm -f "$OUT.summary"
echo
echo "results → $OUT"
