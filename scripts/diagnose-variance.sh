#!/usr/bin/env bash
# diagnose-variance.sh — capture machine-state snapshot before a benchmark run.
#
# Background: HANDOFF.md Round 5 / SWEEP.md report 4.75–14.49 gen tok/s
# variance for qwen36-neo @ 128K, 500-token gen. Run this BEFORE each timed
# run (and again after, optional) so we can correlate variance to thermals,
# GPU power state, and memory pressure.
#
# Usage:
#   ./scripts/diagnose-variance.sh           # writes logs/variance-<ts>.log
#   ./scripts/diagnose-variance.sh --tag pre  # adds a tag to the filename
#   SUDO=1 ./scripts/diagnose-variance.sh    # also runs powermetrics (needs sudo)
#
# Read-only. No server interaction. Safe to run anytime.
#
# Follow-up (out of scope for this script): wrap a 5x back-to-back identical
# 500-token-gen prompt with this snapshot taken before/between/after each run,
# then diff variance-*.log against the print_timing block in launchd.out.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$REPO/logs"
mkdir -p "$LOG_DIR"

TAG=""
if [[ "${1:-}" == "--tag" && -n "${2:-}" ]]; then
  TAG="-$2"
fi

TS="$(date +%Y%m%d-%H%M%S)"
OUT="$LOG_DIR/variance-${TS}${TAG}.log"

section() { printf "\n=== %s ===\n" "$1" >> "$OUT"; }
run()     { printf "$ %s\n" "$*" >> "$OUT"; "$@" >> "$OUT" 2>&1 || echo "(exit $?)" >> "$OUT"; }

{
  echo "diagnose-variance.sh @ $(date -u +%FT%TZ)  (local: $(date +%FT%T%z))"
  echo "host: $(hostname)  uname: $(uname -srm)"
  echo "tag: ${TAG:-<none>}"
} > "$OUT"

# 1) Thermal pressure (no sudo needed)
section "pmset -g therm"
run pmset -g therm

section "pmset -g thermlog (last 5 lines)"
pmset -g thermlog 2>&1 | tail -5 >> "$OUT" || true

# 2) Memory pressure / paging — the "compressor" line is the key signal for
#    GPU starvation on unified-memory Macs (qwen36-neo resident ~22 GB on 64 GB).
section "vm_stat"
run vm_stat

section "memory_pressure -Q"
run memory_pressure -Q

section "sysctl vm (swap + page faults)"
run sysctl vm.swapusage vm.page_free_count vm.pageins vm.pageouts

# 3) Load average + top GPU/CPU consumers (proxy for "background load sensitivity"
#    hypothesis from HANDOFF Round 5).
section "uptime / loadavg"
run uptime

section "top 10 CPU consumers"
ps -Ao pid,pcpu,pmem,rss,comm -r 2>/dev/null | head -11 >> "$OUT"

section "GPU-using processes (ioreg AGXAccelerator clients)"
ioreg -l -w 0 2>/dev/null | grep -iE "AGXAccelerator|IOAccelClient" | head -20 >> "$OUT" || true

# 4) llama-server resident state (so we can spot KV cache growth between runs).
section "llama-server process"
pgrep -fl llama-server >> "$OUT" 2>&1 || echo "(none running)" >> "$OUT"
LLAMA_PID="$(pgrep -f llama-server | head -1 || true)"
if [[ -n "$LLAMA_PID" ]]; then
  ps -o pid,rss,vsz,pcpu,etime,comm -p "$LLAMA_PID" >> "$OUT" 2>&1
fi

# 5) caffeinate / power assertions — was anything keeping the system awake
#    during prior bench runs?
section "pmset -g assertions (filtered)"
pmset -g assertions 2>/dev/null | grep -iE "PreventUserIdleSystemSleep|PreventSystemSleep|caffeinate" >> "$OUT" || true

section "power source"
run pmset -g batt

# 6) GPU power / frequency — only with sudo, otherwise skip silently.
if [[ "${SUDO:-0}" == "1" ]] && command -v powermetrics >/dev/null 2>&1; then
  section "powermetrics -s gpu_power -n 1 (1 sample, ~200ms)"
  sudo -n powermetrics -s gpu_power -n 1 -i 200 >> "$OUT" 2>&1 \
    || echo "(powermetrics requires interactive sudo; rerun with: sudo SUDO=1 $0)" >> "$OUT"
else
  section "powermetrics (skipped)"
  echo "Set SUDO=1 and run via sudo to capture GPU active residency / power." >> "$OUT"
fi

# 7) Recent llama-server timings — last 3 print_timing blocks from launchd.out.
section "tail of launchd.out print_timing (last 3 eval times)"
if [[ -f "$LOG_DIR/launchd.out" ]]; then
  grep -E "eval time =" "$LOG_DIR/launchd.out" | tail -6 >> "$OUT"
fi

echo "wrote $OUT"
