#!/usr/bin/env bash
# Double-click launcher. Starts the TurboQuant server (if not already running)
# and opens the web chat UI in the default browser. Works offline.
set -euo pipefail

# Resolve our repo dir (Finder runs .command files with cwd=$HOME, so use script dir)
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO"

PORT=10501

# Friendly error if the server crashes
trap 'echo; echo "‼ Something went wrong. Press any key to close."; read -n 1 -s' ERR

echo "⏳ Starting Qwen 3.6 (offline)…"

# Already up?
if curl -sf --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  echo "✓ already running on :$PORT"
else
  if [[ ! -x vendor/llama-cpp-turboquant/build/bin/llama-server ]]; then
    echo "‼ TurboQuant build missing. Run ./scripts/build-llama.sh first (needs internet, one-time)."
    read -n 1 -s
    exit 1
  fi
  PORT=$PORT CTX=65536 KV=turbo3 ./scripts/start-turboquant.sh > logs/turboquant.log 2>&1 &
  echo "  log → $REPO/logs/turboquant.log"
  printf "  loading model"
  for i in $(seq 1 90); do
    if curl -sf --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
      echo " ready ($i s)"
      break
    fi
    printf "."
    sleep 1
    [[ $i -eq 90 ]] && { echo; echo "‼ took longer than 90 s — check logs/turboquant.log"; read -n 1 -s; exit 1; }
  done
fi

# Open web demo
URL="file://$REPO/clients/web-demo.html"
echo "🌐 Opening $URL"
open "$URL"

echo
echo "Server: http://127.0.0.1:$PORT"
echo "Stop with: ./scripts/stop-all.sh"
echo
echo "(this window can be closed)"
