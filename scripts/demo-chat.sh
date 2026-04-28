#!/usr/bin/env bash
# Tiny offline chat REPL. Streams tokens, prints tok/s after each reply.
set -euo pipefail
PORT="${PORT:-10501}"
URL="http://127.0.0.1:$PORT/v1/chat/completions"

if ! curl -sf "http://127.0.0.1:$PORT/health" >/dev/null; then
  echo "no server on :$PORT — start one with scripts/start-turboquant.sh"
  exit 1
fi

# History as JSON array on disk so multi-turn works
HIST="$(mktemp -t qwen-hist.XXXXXX.json)"
echo '[]' > "$HIST"
trap 'rm -f "$HIST"' EXIT

echo "Connected to :$PORT  ·  Ctrl-D to quit  ·  /reset to clear history"
echo

while IFS= read -r -p $'\e[36myou> \e[0m' line; do
  [[ -z "$line" ]] && continue
  if [[ "$line" == "/reset" ]]; then echo '[]' > "$HIST"; echo "(history cleared)"; continue; fi

  jq --arg c "$line" '. += [{"role":"user","content":$c}]' "$HIST" > "$HIST.new" && mv "$HIST.new" "$HIST"
  body=$(jq -nc --slurpfile m "$HIST" '{model:"local", stream:true, messages:$m[0], max_tokens:1024}')

  echo -ne "\e[32mqwen> \e[0m"
  REPLY=""
  while IFS= read -r evt; do
    [[ "$evt" == data:* ]] || continue
    payload="${evt#data: }"
    [[ "$payload" == "[DONE]" ]] && break
    chunk=$(echo "$payload" | jq -r '.choices[0].delta.content // empty' 2>/dev/null || true)
    [[ -n "$chunk" ]] && { printf "%s" "$chunk"; REPLY+="$chunk"; }
  done < <(curl -sN "$URL" -H "Content-Type: application/json" -d "$body")
  echo

  jq --arg c "$REPLY" '. += [{"role":"assistant","content":$c}]' "$HIST" > "$HIST.new" && mv "$HIST.new" "$HIST"

  # one more non-stream call just to read /timings of the last gen
  tps=$(curl -sf "http://127.0.0.1:$PORT/v1/chat/completions" -H "Content-Type: application/json" \
    -d "$(jq -nc --slurpfile m "$HIST" '{model:"local", messages:($m[0] + [{role:"user",content:"."}]), max_tokens:1}')" \
    | jq -r '.timings.predicted_per_second // empty' 2>/dev/null || true)
  [[ -n "$tps" ]] && printf "\e[2m  (~%.0f tok/s)\e[0m\n" "$tps"
done
