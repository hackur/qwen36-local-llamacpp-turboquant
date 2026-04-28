#!/usr/bin/env bash
# Needle-in-haystack at long context. Confirms turbo3/q8_0 KV cache actually works
# end-to-end, not just allocates.
set -euo pipefail
PORT="${1:-10501}"
TARGET_TOKENS="${TARGET_TOKENS:-100000}"
NEEDLE="The secret password is fjord-mango-pinwheel-9421."
URL="http://127.0.0.1:$PORT"

# ~4 chars/token → fill to TARGET_TOKENS
CHARS=$((TARGET_TOKENS * 4))
HAYSTACK="$(yes 'The quick brown fox jumps over the lazy dog. ' | head -c "$CHARS")"
PROMPT="${HAYSTACK} ${NEEDLE} ${HAYSTACK}\n\nQuestion: what is the secret password? Answer in one sentence."

echo "▶ Sending ~${TARGET_TOKENS}-token prompt to :$PORT"
START=$(date +%s)
RESP=$(curl -sf "$URL/v1/chat/completions" -H "Content-Type: application/json" \
  -d "$(jq -nc --arg p "$PROMPT" '{model:"local",messages:[{role:"user",content:$p}],max_tokens:80,temperature:0.0}')")
END=$(date +%s)

echo "  elapsed: $((END-START))s"
echo "  reply:   $(echo "$RESP" | jq -r '.choices[0].message.content')"
echo "  prompt_n: $(echo "$RESP" | jq -r '.timings.prompt_n')"
echo "  prompt_per_second: $(echo "$RESP" | jq -r '.timings.prompt_per_second')"

if echo "$RESP" | jq -r '.choices[0].message.content' | grep -q "fjord-mango-pinwheel-9421"; then
  echo "✓ Needle recovered — long context works."
else
  echo "✗ Needle NOT recovered — context truncated or KV-cache lossy."
fi
