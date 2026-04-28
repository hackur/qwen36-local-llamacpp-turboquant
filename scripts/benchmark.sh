#!/usr/bin/env bash
# A/B benchmark: warmup + 3 runs of a fixed 400-word generation prompt
# against any number of ports passed as args (default: baseline + turboquant).
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORTS=("${@:-10500 10501}")
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO/benchmarks/results-$TS.json"
mkdir -p "$REPO/benchmarks"

PROMPT='Explain in detail how transformer attention mechanisms work. Cover self-attention, multi-head attention, key-query-value matrices, and positional encoding. Write at least 400 words.'

bench_one() {
  local port="$1"
  local url="http://127.0.0.1:$port"
  curl -sf "$url/health" >/dev/null || { echo "  :$port not up — skipping"; return; }

  echo "── port $port ──"
  # warmup
  curl -sf "$url/v1/chat/completions" -H "Content-Type: application/json" \
    -d '{"model":"local","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' >/dev/null || true

  local total=0
  for i in 1 2 3; do
    local r
    r=$(curl -sf "$url/v1/chat/completions" -H "Content-Type: application/json" -d "$(jq -nc --arg p "$PROMPT" '{model:"local",messages:[{role:"user",content:$p}],max_tokens:500,chat_template_kwargs:{enable_thinking:false}}')")
    local tps n
    tps=$(echo "$r" | jq -r '.timings.predicted_per_second // 0')
    n=$(echo "$r"   | jq -r '.timings.predicted_n // 0')
    printf "  run %d: %.2f tok/s  (%s tokens)\n" "$i" "$tps" "$n"
    total=$(echo "$total + $tps" | bc -l)
    echo "$r" | jq -c --arg port "$port" --arg run "$i" '{port:$port, run:$run, timings:.timings}' >> "$OUT"
  done
  printf "  avg:   %.2f tok/s\n\n" "$(echo "$total / 3" | bc -l)"
}

for p in "${PORTS[@]}"; do bench_one "$p"; done

echo "results → $OUT"
