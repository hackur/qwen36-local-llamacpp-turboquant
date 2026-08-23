#!/usr/bin/env bash
# Finder launcher for the complete Qwen3.8 runtime and native llama.cpp WebUI.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO"

trap 'echo; echo "Qwen3.8 failed to start. See logs/qwen38.log."; read -n 1 -s' ERR

if ! curl -sf --max-time 1 http://127.0.0.1:10501/health >/dev/null 2>&1; then
  make preflight
  make start
  printf 'Loading Qwen3.8'
  for _ in $(seq 1 90); do
    if curl -sf --max-time 1 http://127.0.0.1:10501/health >/dev/null 2>&1; then
      echo " ready"
      break
    fi
    printf '.'
    sleep 1
  done
fi

open http://127.0.0.1:10501/
echo "Qwen3.8 WebUI: http://127.0.0.1:10501/"
echo "Stop with: make stop"
