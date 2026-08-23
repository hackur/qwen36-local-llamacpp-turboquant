#!/usr/bin/env bash
# Run five fixed quality prompts against the complete Qwen3.8 runtime.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-10501}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO/benchmarks/quality-$TS"

curl -sf --max-time 2 "http://127.0.0.1:$PORT/health" >/dev/null || {
  echo "Qwen3.8 is not healthy on :$PORT" >&2
  exit 1
}
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
      -d "$(jq -nc --arg p "$p" '{model:"qwen3.8-local",messages:[{role:"user",content:$p}],max_tokens:600,temperature:0.7,top_p:0.8,top_k:20,min_p:0.0,presence_penalty:1.5,reasoning_effort:"none",chat_template_kwargs:{enable_thinking:false}}')")
    out=$(echo "$resp" | python3 -c "import sys,json; r=json.load(sys.stdin,strict=False); print(r['choices'][0]['message']['content'])")
    echo "$out" | tee "$OUT/$tag-$i.txt"
    echo
  done
}

run_one "$PORT" qwen38-full

echo "outputs → $OUT"
