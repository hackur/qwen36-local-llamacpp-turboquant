#!/usr/bin/env bash
# Switch the local runtime between model profiles by env file.
#
# Usage:
#   ./scripts/switch-model.sh crow-9b [--restart] [--with-proxy]
#   ./scripts/switch-model.sh qwen38      # default 27B profile (runtime.env)
#
# Profiles live in configs/models/<name>.env. The "qwen38" profile is the
# built-in default: it sources no env file and starts with runtime.env values.
# Each switch stops whatever is running (make stop), then starts the chosen
# profile in the background with logs appended to logs/qwen38.log.
#
# Flags:
#   --restart     No-op today: switching ALWAYS stops the running server and
#                 starts the chosen profile. Accepted for explicitness and
#                 future use (e.g. partial restart that keeps the proxy).
#   --with-proxy  Also restart the compaction proxy after the model comes up
#                 (proxy.sh start). The proxy expects the running model alias:
#                 qwen38 -> qwen3.8-local, crow-9b -> crow-9b-local. Clients
#                 pointed at :11500 keep working after a switch.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  local profiles
  profiles="$(ls "$REPO/configs/models"/*.env 2>/dev/null | xargs -n1 basename | sed 's/\.env$//' | tr '\n' ' ')"
  echo "usage: $(basename "$0") <profile> [--restart] [--with-proxy]"
  echo "profiles: ${profiles}qwen38 (default 27B)"
}

PROFILE=""
WITH_PROXY=0
for arg in "$@"; do
  case "$arg" in
    --restart) ;;  # switching always restarts the model server
    --with-proxy) WITH_PROXY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) [[ -z "$PROFILE" ]] || { usage; exit 2; }
       PROFILE="$arg" ;;
  esac
done
[[ -n "$PROFILE" ]] || { usage; exit 2; }

ENV_FILE="$REPO/configs/models/$PROFILE.env"
case "$PROFILE" in
  qwen38|27b)
    ENV_FILE="" ;;
  *)
    [[ -f "$ENV_FILE" ]] || { usage; exit 2; }
    ;;
esac

log="Switching to profile: ${PROFILE}"
if [[ -n "$ENV_FILE" ]]; then
  log="$log ($ENV_FILE)"
fi

# Resolve the selected profile before primary defaults; import the health helper.
if [[ -n "$ENV_FILE" ]]; then
  set -a
  source "$ENV_FILE"
  set +a
fi
source "$REPO/scripts/_common.sh"

# 1) Stop whatever is running (proxy + launchd + repo llama-servers).
"$REPO/scripts/stop-all.sh"

# 2) Start the chosen profile. Sourcing the env file before _common.sh lets
#    its : "${VAR:=...}" defaults see the profile values first. The server is
#    started exactly like `make start`: backgrounded, log appended.
#    shellcheck disable=SC1090
mkdir -p "$REPO/logs"
if [[ -n "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  # Export so the child start-turboquant.sh (a new process) inherits the
  # profile values. start-turboquant.sh sources _common.sh which fills any
  # still-unset vars from runtime.env defaults.
  export MODEL_FILE MMPROJ_FILE MODEL_NAME CTX MTP
fi
# The subshell's own stdout/stderr are detached too (nohup-style), so no fd of
# this script or its caller can be held open by the server chain.
( cd "$REPO" && ./scripts/start-turboquant.sh >> "$REPO/logs/qwen38.log" 2>&1 & disown ) >/dev/null 2>&1

# 3) Wait (bounded) for the listener so failures surface immediately.
# The 27B load can take 20-40 s; allow 240 s to be safe. The server pid is
# looked up by port after health, not $! (the subshell re-parents the child).
if wait_for_health "$PORT" 240; then
  SERVER_PID="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
  # 4) Optional: bring the compaction proxy back up against the new alias.
  if (( WITH_PROXY )); then
    if "$REPO/scripts/proxy.sh" start >/dev/null; then
      log="$log + proxy"
    else
      echo "WARNING: model switched but proxy failed to start; check logs/proxy-run.log" >&2
    fi
  fi
  echo "$log — up on http://127.0.0.1:$PORT (pid $SERVER_PID)"
  exit 0
fi
echo "$log — ERROR: no healthy server on :$PORT within 240 s; check logs/qwen38.log" >&2
exit 1
