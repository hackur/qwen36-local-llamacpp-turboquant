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

# Healthcheck used by install: after loading, the KeepAlive job must bring up
# a listener on 10501 within the bounded wait. The 27B Q8_0 load on MTL0 takes
# roughly 20-40 s, so allow 180 s before declaring failure.
wait_for_listener() {
  local deadline=$(( $(date +%s) + 180 )) pid
  while (( $(date +%s) < deadline )); do
    if pid="$(port_pid)" && [[ -n "$pid" ]]; then
      echo "listener: port 10501 up (pid $pid)"
      return 0
    fi
    sleep 3
  done
  echo "ERROR: no listener on 10501 after 180 s" >&2
  echo "  check logs/launchd.err and logs/qwen38.log" >&2
  return 1
}

# End-to-end bootstrap verification for a fresh checkout. Every step must
# pass or install fails with an actionable message; nothing is left half-set.
run_install_check() {
  local launcher="$REPO/scripts/start-turboquant.sh"
  if [[ ! -x "$REPO/vendor/llama-cpp-turboquant/build/bin/llama-server" ]]; then
    echo "ERROR: vendor/llama-cpp-turboquant/build/bin/llama-server not found" >&2
    echo "  run 'make build' first (or set TURBOQUANT_BIN)" >&2
    return 1
  fi
  if [[ ! -x "$launcher" ]]; then
    echo "ERROR: launcher not executable: $launcher" >&2
    return 1
  fi
  if [[ ! -f "$REPO/configs/launchd-plist.template" ]]; then
    echo "ERROR: configs/launchd-plist.template missing" >&2
    return 1
  fi
  "$0" register
  wait_for_listener
}

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
  install)
    run_install_check
    ;;
  register)
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
    echo "usage: $0 {status|register|install|start|stop|restart|unregister}" >&2
    exit 2
    ;;
esac
