#!/usr/bin/env bash
# Stop any llama-server processes started from this repo.
#
# Two-phase, race-tolerant:
#   1. SIGTERM every match, wait briefly, SIGKILL anything still alive.
#   2. Re-scan in a bounded loop — catches stragglers that were spawned during
#      the first pass (we've seen pids appear between SIGTERM and SIGKILL).
#   3. Final verification: if anything survives, print it and exit non-zero so
#      callers (and the new ensure_no_other_llama_server guard) know cleanup
#      didn't actually succeed.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PATTERNS=(
  "vendor/llama.cpp-mainline.*llama-server"
  "vendor/llama-cpp-turboquant.*llama-server"
)

list_pids() {
  local pat
  for pat in "${PATTERNS[@]}"; do
    pgrep -f "$pat" 2>/dev/null || true
  done | sort -u
}

found_any=0
max_passes=5
for ((pass=1; pass<=max_passes; pass++)); do
  pids=()
  while read -r pid; do [[ -n "$pid" ]] && pids+=("$pid"); done < <(list_pids)
  (( ${#pids[@]} == 0 )) && break

  found_any=1
  for pid in "${pids[@]}"; do
    cmd=$(ps -p "$pid" -o command= 2>/dev/null | head -c 120)
    echo "  [pass $pass] kill $pid : $cmd"
    kill "$pid" 2>/dev/null || true
  done

  sleep 2

  # SIGKILL anything still alive from this pass.
  for pid in "${pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then
      echo "  [pass $pass] SIGKILL $pid (didn't exit gracefully)"
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
done

if [[ $found_any -eq 0 ]]; then
  echo "(no llama-server processes from this repo were running)"
  exit 0
fi

# Verify: nothing should remain. If something does, surface it loudly.
remaining=()
while read -r pid; do [[ -n "$pid" ]] && remaining+=("$pid"); done < <(list_pids)
if (( ${#remaining[@]} > 0 )); then
  echo "❌ Survivors after $max_passes passes — investigate manually:" >&2
  for pid in "${remaining[@]}"; do
    ps -p "$pid" -o pid=,ppid=,command= 2>/dev/null >&2 || true
  done
  exit 1
fi

echo "✓ stopped"
