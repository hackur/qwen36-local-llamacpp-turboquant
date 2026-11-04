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
source "$REPO/scripts/_common.sh"   # provides PORT_PROXY
PORT="$PORT_PROXY"

# The proxy is identified by its listening port (its command line is the
# unhelpful "node src/index.js"). The two-phase kill + verify lives in
# _common.sh so it matches stop-all.sh exactly.
proxy_pids() { list_pids_by_port "$PORT"; }
if ! kill_pids_by proxy_pids 5; then
  exit 1
fi

echo "✓ stopped compaction proxy (:$PORT)"
