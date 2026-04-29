#!/usr/bin/env bash
# Long-context recall test. Thin wrapper that delegates to scripts/needle.py
# (the bash version with jq + yes piping was unreliable on huge prompts).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${TARGET_TOKENS:-50000}"
PORT="${1:-10501}"
DEPTH="${2:-50}"
exec python3 "$SCRIPT_DIR/needle.py" "$TARGET" "$PORT" "$DEPTH"
