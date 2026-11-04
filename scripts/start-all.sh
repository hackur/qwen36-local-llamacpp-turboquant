#!/usr/bin/env bash
# Start the full local stack in the background: the model server (a profile)
# plus the compaction proxy. Laya is started only when LAYA=1 — it is an
# optional classifier the proxy can use, not a required component.
#
# Usage:
#   ./scripts/start-all.sh [profile]   # profile: qwen38 (default) or a
#                                      # configs/models/<name>.env name
#   LAYA=1 ./scripts/start-all.sh      # also (re)start the Laya classifier
#
# The model is started via scripts/restart-turboquant.sh (stop + background
# start + bounded health wait) so a partially-up or stale server is always
# replaced. The proxy comes up afterwards so its /proxy/info upstream probe
# always finds a healthy model. `make stop-all` / `scripts/stop-all.sh` is
# the inverse; the proxy and laya stop paths there are idempotent no-ops
# when nothing is running.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/scripts/_common.sh"   # PORT, PORT_PROXY, PORT_LAYA, wait_for_health

PROFILE="${1:-qwen38}"
LAYA="${LAYA:-0}"

case "$PROFILE" in
  qwen38|27b) ;;
  *) [[ -f "$REPO/configs/models/$PROFILE.env" ]] || {
       echo "unknown profile: $PROFILE (no configs/models/$PROFILE.env)" >&2
       exit 2; } ;;
esac

echo "=== start-all: profile=$PROFILE laya=$LAYA ==="

# 1) Model server (stop any stale instance, background start, bounded wait).
case "$PROFILE" in
  qwen38|27b) PROFILE="$PROFILE" "$REPO/scripts/restart-turboquant.sh" ;;
  *) "$REPO/scripts/switch-model.sh" "$PROFILE" ;;
esac

# 2) Compaction proxy (no-op with a friendly message if already up).
"$REPO/scripts/proxy.sh" start

# 3) Optional Laya classifier (launchd-managed; needs make laya-install first).
if [[ "$LAYA" == "1" ]]; then
  if command -v launchctl >/dev/null 2>&1; then
    "$REPO/scripts/laya.sh" restart
  else
    echo "LAYA=1 but launchctl not available (non-Darwin?) — skipping laya" >&2
  fi
fi

echo "=== start-all done ==="
"$REPO/scripts/status.sh"
