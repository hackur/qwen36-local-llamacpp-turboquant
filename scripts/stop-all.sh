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
source "$REPO/scripts/_common.sh"   # kill_pids_by, list_pids_by_repo_cmd

if [[ "${1:-}" != "--processes-only" ]]; then
  [[ $# -eq 0 ]] || { echo "usage: $0 [--processes-only]" >&2; exit 2; }
  "$REPO/scripts/stop-proxy.sh"
  if [[ "$(uname -s)" == Darwin ]]; then
    "$REPO/scripts/service.sh" stop
    exit
  fi
fi

# The two-phase kill + verify is in _common.sh. list_pids_by_repo_cmd matches
# the repo llama-server build paths via ps (NOT pgrep — the 700+ char command
# line exceeds pgrep's scan limit; ps -ww prints the full command line so the
# anchored vendor-path patterns cannot hit unrelated llama-server processes).
if kill_pids_by list_pids_by_repo_cmd 5; then
  echo "✓ stopped llama-server processes"
else
  exit 1
fi
