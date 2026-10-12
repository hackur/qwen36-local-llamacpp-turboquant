#!/usr/bin/env bash
# Stop the compaction proxy started from this repository.
#
# The proxy is started via "cd proxy && npm start", so its command line is the
# unhelpful "node src/index.js" — a pgrep pattern can neither target it nor
# avoid killing unrelated node processes. The proxy is therefore identified by
# its listening port (11500, per proxy/config.yaml). Same two-phase,
# race-tolerant discipline as stop-all.sh: SIGTERM, wait, SIGKILL stragglers,
# re-scan in a bounded loop, verify nothing survives.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT=11500

list_pids() {
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true
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
  echo "(no process is listening on the compaction proxy port :$PORT)"
  exit 0
fi

# Verify: nothing should remain. If something does, surface it loudly.
remaining=()
while read -r pid; do [[ -n "$pid" ]] && remaining+=("$pid"); done < <(list_pids)
if (( ${#remaining[@]} > 0 )); then
  echo "❌ Proxy survivors on :$PORT after $max_passes passes — investigate manually:" >&2
  for pid in "${remaining[@]}"; do
    ps -p "$pid" -o pid=,ppid=,command= 2>/dev/null >&2 || true
  done
  exit 1
fi

echo "✓ stopped compaction proxy (:$PORT)"
