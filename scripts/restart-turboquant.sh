#!/usr/bin/env bash
# Restart the turboquant model server on :$PORT with launchd owning its
# lifecycle.
#
# The launchd agent (configs/launchd-plist.template) runs
# start-turboquant.sh foreground, which execs llama-server as the job's direct
# child: launchd sends SIGTERM/SIGKILL and restarts on crash, and no shell
# stays parent of the server, so no caller can be held open by the server's
# fd table. This script is a thin, fast (no 20-40 s server-side wait) wrapper:
#   1. stop the proxy + any loose repo server processes + the job,
#   2. (re)bootstrap the job — the job starts the server on its own,
#   3. bounded health wait on :$PORT.
#
# Requires the macOS login agent: run 'make service-register' once (or
# 'make install-launchd'). Other profiles (crow-9b) have no launchd template;
# for those, restart with the manual pattern:
#   source configs/models/crow-9b.env
#   ( ./scripts/start-turboquant.sh >> logs/qwen38.log 2>&1 & disown ) >/dev/null 2>&1
#
# Usage: PROFILE=qwen38 ./scripts/restart-turboquant.sh   (qwen38 = default)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/_common.sh"   # PORT, wait_for_health, ...

PROFILE="${PROFILE:-qwen38}"
case "$PROFILE" in
  qwen38|27b) ;;
  *) die "restart supports the launchd-managed qwen38 profile; for $PROFILE see the header comment" ;;
esac

[[ "$(uname -s)" == Darwin ]] || die "restart requires the macOS launchd agent (make service-register)"

# 1) Stop everything the job would race with: proxy, loose server processes,
#    and the launchd job itself (stop boots it out, plist retained).
"$REPO/scripts/stop-all.sh"

# 2) Re-bootstrap from the current template (register renders + plutil-lints
#    every time, so the plist always tracks the checked-in configuration).
#    RunAtLoad starts the server; the job owns its lifecycle from here.
#    If a server still owns :$PORT (e.g. stop-all could not reach it), refuse
#    to bootstrap a job that would crash-loop on the port bind.
mkdir -p "$REPO/logs"
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
  die "port $PORT is still in use after stop-all; investigate before restart"
fi
"$REPO/scripts/service.sh" register

# 3) Bounded wait so load failures surface (27B load: 20-40 s).
if wait_for_health "$PORT" 240; then
  SERVER_PID="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
  echo "profile $PROFILE restarted via launchd on http://127.0.0.1:$PORT (pid ${SERVER_PID:-?})"
  exit 0
fi
echo "ERROR: no healthy server on :$PORT within 240 s; check logs/qwen38.log and logs/launchd.err" >&2
exit 1
