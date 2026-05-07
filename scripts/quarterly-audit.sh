#!/usr/bin/env bash
# Quarterly offline re-validation. LM Studio updates can move model paths and
# reintroduce online dependencies; this script catches both.
#
# Checks:
#   1. `make audit-offline` against the live :10501 turboquant server (and the
#      :11500 compaction proxy if it is running).
#   2. Every symlink under ./models/ resolves to an existing file (catches LM
#      Studio path changes after a major version update).
#   3. `scripts/privacy-scan.sh` over the whole repo.
#
# Output: a timestamped report at logs/quarterly-audit-YYYY-MM-DD.log.
# Exit code: non-zero on any failure (broken symlink, non-localhost socket,
# privacy-scan hit, or server audit failure).
#
# Run manually any time:   make quarterly-audit
# Run on a 90-day schedule: see configs/launchd-quarterly.template
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

mkdir -p "$REPO/logs"
STAMP="$(date +%Y-%m-%d)"
LOG="$REPO/logs/quarterly-audit-$STAMP.log"
: > "$LOG"

fail=0
section() {
  printf '\n=== %s ===\n' "$1" | tee -a "$LOG"
}
log() { echo "$@" | tee -a "$LOG"; }

log "Quarterly offline re-validation — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "Repo: $REPO"

# -----------------------------------------------------------------------------
section "Server sockets"
# -----------------------------------------------------------------------------

# TurboQuant llama-server (:10501)
TQ_PID="$(pgrep -f 'vendor/llama-cpp-turboquant.*llama-server' | head -1 || true)"
if [[ -n "$TQ_PID" ]]; then
  log "turboquant llama-server PID=$TQ_PID — running make audit-offline"
  if make audit-offline >>"$LOG" 2>&1; then
    log "  PASS: turboquant has zero non-localhost sockets"
  else
    log "  FAIL: turboquant audit-offline reported non-localhost sockets"
    fail=1
  fi
else
  log "turboquant llama-server not running on :10501 — skipping audit-offline"
  log "  (run \`make start\` first for a full audit)"
fi

# Compaction proxy (:11500), if running
PROXY_PID="$(lsof -nP -iTCP:11500 -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
if [[ -n "$PROXY_PID" ]]; then
  log "compaction proxy PID=$PROXY_PID on :11500 — checking sockets"
  non_local="$(lsof -nP -p "$PROXY_PID" 2>/dev/null | grep -E 'TCP|UDP' | grep -vE '127\.0\.0\.1|\[::1\]' || true)"
  if [[ -z "$non_local" ]]; then
    log "  PASS: proxy has zero non-localhost sockets"
  else
    log "  FAIL: proxy has non-localhost sockets:"
    echo "$non_local" | tee -a "$LOG"
    fail=1
  fi
else
  log "compaction proxy not running on :11500 — skipping"
fi

# -----------------------------------------------------------------------------
section "Symlink integrity"
# -----------------------------------------------------------------------------
shopt -s nullglob
links=("$REPO/models"/*.gguf)
if (( ${#links[@]} == 0 )); then
  log "  FAIL: no symlinks found under models/ — run scripts/symlink-models.sh"
  fail=1
else
  ok=0; broken=0
  for link in "${links[@]}"; do
    name="$(basename "$link")"
    if [[ -L "$link" ]]; then
      target="$(readlink "$link")"
      if [[ -f "$link" ]]; then
        log "  ok    $name -> $target"
        ok=$((ok+1))
      else
        log "  BROKEN $name -> $target (target missing — LM Studio likely moved it)"
        broken=$((broken+1))
        fail=1
      fi
    elif [[ -f "$link" ]]; then
      log "  file  $name (regular file, not a symlink)"
      ok=$((ok+1))
    fi
  done
  log "  summary: $ok ok, $broken broken"
fi

# -----------------------------------------------------------------------------
section "Privacy scan results"
# -----------------------------------------------------------------------------
if "$REPO/scripts/privacy-scan.sh" >>"$LOG" 2>&1; then
  log "  PASS: privacy scan clean"
else
  log "  FAIL: privacy scan found matches (see above)"
  fail=1
fi

# -----------------------------------------------------------------------------
section "Result"
# -----------------------------------------------------------------------------
if (( fail == 0 )); then
  log "OVERALL: PASS  ($LOG)"
  exit 0
else
  log "OVERALL: FAIL  ($LOG)"
  exit 1
fi
