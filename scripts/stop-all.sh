#!/usr/bin/env bash
# Stop any llama-server processes started from this repo.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

found=0
for pat in "vendor/llama.cpp-mainline.*llama-server" "vendor/llama-cpp-turboquant.*llama-server"; do
  for pid in $(pgrep -f "$pat" 2>/dev/null); do
    cmd=$(ps -p "$pid" -o command= | head -c 120)
    echo "  kill $pid : $cmd"
    kill "$pid" 2>/dev/null && found=1
  done
done

if [[ $found -eq 0 ]]; then
  echo "(no llama-server processes from this repo were running)"
  exit 0
fi

# Wait briefly for graceful exit, then SIGKILL stragglers
sleep 2
for pat in "vendor/llama.cpp-mainline.*llama-server" "vendor/llama-cpp-turboquant.*llama-server"; do
  for pid in $(pgrep -f "$pat" 2>/dev/null); do
    echo "  SIGKILL $pid (didn't exit gracefully)"
    kill -9 "$pid" 2>/dev/null
  done
done

echo "✓ stopped"
