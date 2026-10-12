#!/usr/bin/env bash
# Install, download, and manage the local Laya classifier on :18000.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="$REPO/vendor/laya-venv/bin/python"
LABEL=com.local.qwen.laya
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
TARGET="gui/$(id -u)/$LABEL"

case "${1:-status}" in
  install)
    if [[ ! -x "$PYTHON" ]]; then uv venv --python 3.13 "$REPO/vendor/laya-venv"; fi
    uv pip install --python "$PYTHON" --link-mode copy 'torch==2.12.0' 'laya[serve]==0.3.25'
    "$PYTHON" "$REPO/scripts/laya-download.py"
    ;;
  download) "$PYTHON" "$REPO/scripts/laya-download.py" ;;
  foreground)
    export HF_HUB_OFFLINE=1
    exec "$PYTHON" "$REPO/scripts/laya-server.py"
    ;;
  start)
    [[ -x "$PYTHON" ]] || { echo "run make laya-install first" >&2; exit 1; }
    if launchctl print "$TARGET" >/dev/null 2>&1; then
      launchctl kickstart "$TARGET"
    else
      if lsof -nP -iTCP:18000 -sTCP:LISTEN -t >/dev/null 2>&1; then
        echo "port 18000 is already occupied" >&2; exit 1
      fi
      mkdir -p "$REPO/logs" "$(dirname "$PLIST")"
      python3 - "$REPO" "$PLIST" "$LABEL" <<'PY'
import plistlib, sys
from pathlib import Path
repo, output, label = sys.argv[1:]
config = dict(Label=label, ProgramArguments=[str(Path(repo)/'scripts/laya.sh'), 'foreground'],
              WorkingDirectory=repo, RunAtLoad=True, KeepAlive=True, ThrottleInterval=10,
              EnvironmentVariables={'PATH':'/opt/homebrew/bin:/usr/bin:/bin',
                                    'HF_HUB_OFFLINE':'1', 'LAYA_DEVICE':'cpu', 'LAYA_THREADS':'8'},
              StandardOutPath=str(Path(repo)/'logs/laya.log'),
              StandardErrorPath=str(Path(repo)/'logs/laya.log'))
with open(output,'wb') as f: plistlib.dump(config,f)
PY
      launchctl bootstrap "gui/$(id -u)" "$PLIST"
    fi
    echo "Laya login service started; readiness: make laya-status"
    ;;
  stop)
    if launchctl print "$TARGET" >/dev/null 2>&1; then launchctl bootout "$TARGET"; fi
    echo "Laya stopped; login plist retained"
    ;;
  status) curl -fsS --max-time 3 http://127.0.0.1:18000/health; echo ;;
  *) echo "usage: $0 {install|download|foreground|start|stop|status}" >&2; exit 2 ;;
esac
