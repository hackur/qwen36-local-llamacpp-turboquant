#!/usr/bin/env bash
# Stop the launchd agent, any llama-server processes, and the compaction proxy
# started from this repo.
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

if [[ "${1:-}" != "--processes-only" ]]; then
  [[ $# -eq 0 ]] || { echo "usage: $0 [--processes-only]" >&2; exit 2; }
  "$REPO/scripts/stop-proxy.sh"
  if [[ "$(uname -s)" == Darwin ]]; then
    "$REPO/scripts/service.sh" stop
    exit
  fi
fi

list_pids() {
  # NOTE: pgrep -f cannot see the llama-server on this system (its 700+ char
  # command line exceeds what pgrep scans), so match with ps instead. ps -ww
  # prints the full command line, so the anchored vendor-path patterns keep
  # working and cannot hit unrelated llama-server processes.
  /bin/ps -axww -o pid=,command= | awk -v repo="$REPO" '
    index($0, repo "/vendor/llama.cpp-mainline/build/bin/llama-server")     { print $1 }
    index($0, repo "/vendor/llama-cpp-turboquant/build/bin/llama-server")    { print $1 }
  ' | sort -u
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
  echo "(no model server or proxy processes from this repo were running)"
  exit 0
fi

# Verify: nothing should remain. If something does, surface it loudly.
remaining=()
while read -r pid; do [[ -n "$pid" ]] && remaining+=("$pid"); done < <(list_pids)
if (( ${#remaining[@]} > 0 )); then
  echo "❌ Survivors after $max_passes passes (model servers and proxy) — investigate manually:" >&2
  for pid in "${remaining[@]}"; do
    ps -p "$pid" -o pid=,ppid=,command= 2>/dev/null >&2 || true
  done
  exit 1
fi

echo "✓ stopped llama-server processes and compaction proxy"
