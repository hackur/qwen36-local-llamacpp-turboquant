#!/usr/bin/env bash
# Thin CLI wrapper around wait_for_health so the Makefile (which cannot call a
# shell function directly) can block until a port is healthy.
# Usage: _wait.sh <port> [timeout_s] [path]
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/_common.sh
source "$REPO/scripts/_common.sh"
wait_for_health "$@"
