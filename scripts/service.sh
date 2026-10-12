#!/usr/bin/env bash
# Manage the per-user macOS launchd agent for the Qwen3.8 model server.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL=com.local.qwen3-8.turboquant
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
TARGET="gui/$(id -u)/$LABEL"
DOMAIN="gui/$(id -u)"

[[ "$(uname -s)" == Darwin ]] || { echo "launchd service management requires macOS" >&2; exit 1; }

loaded() { launchctl print "$TARGET" >/dev/null 2>&1; }
port_pid() { lsof -nP -iTCP:10501 -sTCP:LISTEN -t 2>/dev/null || true; }
ensure_port_available() {
  local pid
  pid="$(port_pid)"
  [[ -z "$pid" ]] || { echo "port 10501 is already in use by pid(s) ${pid//$'\n'/,}; stop that server first" >&2; exit 1; }
}

case "${1:-}" in
  status)
    if [[ -f "$PLIST" ]]; then echo "registered: $PLIST"; else echo "unregistered"; fi
    if loaded; then
      echo "loaded: $TARGET"
      launchctl list | awk -v label="$LABEL" '$3 == label {print "launchd pid=" $1 " last_exit=" $2}'
    else
      echo "stopped: launchd job is not loaded"
    fi
    if pids="$(port_pid)" && [[ -n "$pids" ]]; then
      echo "port 10501 listener pid(s): ${pids//$'\n'/,}"
    else
      echo "port 10501: no listener"
    fi
    ;;
  register|install)
    if [[ ! -f "$PLIST" ]]; then
      mkdir -p "$(dirname "$PLIST")" "$REPO/logs"
      # Escape sed replacement metacharacters in the checkout path.
      escaped_repo="$(printf '%s' "$REPO" | sed 's/[&|\\]/\\&/g')"
      sed "s|__REPO__|$escaped_repo|g" "$REPO/configs/launchd-plist.template" > "$PLIST"
      plutil -lint "$PLIST" >/dev/null
      echo "registered: $PLIST"
    else
      echo "using existing plist (local settings preserved): $PLIST"
    fi
    if ! loaded; then ensure_port_available; launchctl bootstrap "$DOMAIN" "$PLIST"; fi
    echo "loaded: $TARGET"
    ;;
  start)
    [[ -f "$PLIST" ]] || { echo "service is unregistered; run 'make service-register'" >&2; exit 1; }
    if loaded; then
      service_pid="$(launchctl list | awk -v label="$LABEL" '$3 == label {print $1}')"
      if [[ -z "$service_pid" || "$service_pid" == "-" ]]; then launchctl kickstart "$TARGET"; fi
    else
      ensure_port_available
      launchctl bootstrap "$DOMAIN" "$PLIST"
    fi
    echo "started: $TARGET (model readiness may take time)"
    ;;
  stop)
    if loaded; then launchctl bootout "$TARGET"; fi
    # A previous kill may have orphaned a server outside the launchd job.
    "$REPO/scripts/stop-all.sh" --processes-only
    loaded && { echo "service remained loaded" >&2; exit 1; }
    echo "stopped: $TARGET (plist retained)"
    ;;
  restart)
    "$0" stop
    "$0" start
    ;;
  unregister|uninstall)
    "$0" stop
    if [[ -f "$PLIST" ]]; then rm "$PLIST"; fi
    echo "unregistered: $TARGET"
    ;;
  *)
    echo "usage: $0 {status|register|start|stop|restart|unregister}" >&2
    exit 2
    ;;
esac
