#!/usr/bin/env bash
# Run 5 fixed prompts on baseline vs turboquant. Diff is informational, not pass/fail.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO/benchmarks/quality-$TS"
mkdir -p "$OUT"

PROMPTS=(
  "What is 23 * 47 + 18? Show your work."
  "Refactor this Python: def f(x):\\n  r=[]\\n  for i in x:\\n    r.append(i*i)\\n  return r"
  "Summarize the plot of Macbeth in 3 sentences."
  "Extract a JSON object with keys name, age, city from: 'Sarah, 34, lives in Berlin.' Output JSON only."
  "What was the last sentence I will write before this one? Just kidding — answer: what is the capital of Mongolia?"
)

run_one() {
  local port="$1" tag="$2"
  echo "── $tag (:$port) ──"
  local i=0
  for p in "${PROMPTS[@]}"; do
    i=$((i+1))
    echo "[$i] $p"
    resp=$(curl -sf "http://127.0.0.1:$port/v1/chat/completions" -H "Content-Type: application/json" \
      -d "$(jq -nc --arg p "$p" '{model:"local",messages:[{role:"user",content:$p}],max_tokens:300,temperature:0.6}')")
    out=$(echo "$resp" | jq -r '.choices[0].message.content')
    echo "$out" | tee "$OUT/$tag-$i.txt"
    echo
  done
}

run_one 10500 baseline   2>/dev/null || echo "  (skipped — :10500 not up)"
run_one 10501 turboquant 2>/dev/null || echo "  (skipped — :10501 not up)"

echo "outputs → $OUT"
