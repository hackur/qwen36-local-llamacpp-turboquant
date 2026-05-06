#!/usr/bin/env bash
# Thin shim → scripts/demo-chat.py. Kept so `make demo`, prior muscle memory,
# and the launchd-era `THINK=1 ./scripts/demo-chat.sh` invocation all keep
# working. The Python module owns the behavior contract; see its docstring
# and docs/demo-chat.md.
set -euo pipefail
exec python3 "$(dirname "$0")/demo-chat.py" "$@"
