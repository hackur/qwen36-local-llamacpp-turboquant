#!/usr/bin/env bash
# Manage the compaction proxy on :$PORT_PROXY (11500).
#
# The proxy is a Node service (proxy/). `start` runs it in the BACKGROUND
# (nohup + disown, log -> logs/proxy-run.log) so it survives the calling shell
# and does not block the terminal — the old `make proxy-start` ran `npm start`
# in the foreground, which is how the proxy got orphaned / forgotten. `stop`
# reuses the shared two-phase kill from _common.sh (identical to stop-proxy.sh).
#
# Usage: ./scripts/proxy.sh {start|stop|restart|status|foreground}
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/scripts/_common.sh"   # PORT_PROXY, wait_for_health, list_pids_by_port, kill_pids_by
PROXY_DIR="$REPO/proxy"
LOG="$REPO/logs/proxy-run.log"

is_up() {
  curl -sf --max-time 1 "http://127.0.0.1:$PORT_PROXY/proxy/info" >/dev/null 2>&1
}

case "${1:-status}" in
  start)
    if is_up; then
      pid="$(list_pids_by_port "$PORT_PROXY" | head -1)"
      echo "proxy already running on :$PORT_PROXY (pid ${pid:-?})"
      exit 0
    fi
    [[ -f "$PROXY_DIR/node_modules/.package-lock.json" ]] || {
      echo "proxy deps missing; run 'make proxy-install' first" >&2; exit 1; }
    mkdir -p "$REPO/logs"
    # nohup + background + disown so the proxy outlives this script's shell and
    # does not block the terminal. We find its pid by port after health, not by
    # $!, because the subshell re-parents the child.
    #
    # The whole subshell's stdout/stderr are redirected to /dev/null: nohup
    # handles node's fds, but this script's own inherited fd 1/2 are what
    # keep the caller's pipe (terminal, CI runner, chat session) blocked while
    # proxy.sh start stays alive as node's parent. Without this, "start" hangs
    # the caller until the proxy is killed.
    ( cd "$PROXY_DIR" && nohup node src/index.js >> "$LOG" 2>&1 & disown ) >/dev/null 2>&1
    if wait_for_health "$PORT_PROXY" 30 "/proxy/info"; then
      pid="$(list_pids_by_port "$PORT_PROXY" | head -1)"
      echo "proxy started on :$PORT_PROXY (pid ${pid:-?}); log -> ${LOG#"$REPO"/}"
    else
      echo "proxy failed to become healthy on :$PORT_PROXY within 30 s; check ${LOG#"$REPO"/}" >&2
      exit 1
    fi
    ;;
  stop)
    proxy_pids() { list_pids_by_port "$PORT_PROXY"; }
    if ! kill_pids_by proxy_pids 5; then
      exit 1
    fi
    echo "proxy stopped (:$PORT_PROXY)"
    ;;
  restart)
    "$0" stop
    "$0" start
    ;;
  foreground)
    # Run in the foreground of the caller (for debugging). Blocks until Ctrl-C.
    ( cd "$PROXY_DIR" && exec node src/index.js )
    ;;
  status)
    if is_up; then
      info="$(curl -sf --max-time 1 "http://127.0.0.1:$PORT_PROXY/proxy/info")"
      pid="$(list_pids_by_port "$PORT_PROXY" | head -1)"
      mode="$(jq -r '.mode // "?"' <<< "$info")"
      echo "proxy up on :$PORT_PROXY (pid ${pid:-?}) mode=$mode"
    else
      echo "proxy down (:$PORT_PROXY)"
    fi
    ;;
  *)
    echo "usage: $0 {start|stop|restart|status|foreground}" >&2; exit 2 ;;
esac
