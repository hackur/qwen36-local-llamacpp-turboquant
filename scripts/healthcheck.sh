#!/usr/bin/env bash
# Smoke-test a running llama-server. Default port 10501 (turboquant).
set -euo pipefail
PORT="${1:-10501}"
URL="http://127.0.0.1:$PORT"

echo "── $URL/health ──"
curl -sf "$URL/health" || { echo "server not up on :$PORT"; exit 1; }
echo

echo "── $URL/v1/models ──"
curl -s "$URL/v1/models" | python3 -m json.tool
echo

echo "── completion + tok/s (thinking off) ──"
curl -s "$URL/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"Say hi in 5 words."}],"max_tokens":40,"chat_template_kwargs":{"enable_thinking":false}}' \
  | python3 -c "
import json, sys
r = json.loads(sys.stdin.read(), strict=False)  # tolerate raw control chars in content
msg = r['choices'][0]['message']['content']
t = r.get('timings', {})
print(f'  reply: {msg!r}')
print(f'  predicted_per_second: {t.get(\"predicted_per_second\", 0):.1f} tok/s')
print(f'  prompt_per_second:    {t.get(\"prompt_per_second\", 0):.1f} tok/s')
"
