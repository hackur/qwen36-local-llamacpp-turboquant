#!/usr/bin/env bash
# Sample unified-memory pressure while a server runs. Writes CSV to benchmarks/.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO/benchmarks/mem-$TS.csv"
mkdir -p "$REPO/benchmarks"

echo "ts,wired_mb,active_mb,inactive_mb,free_mb,compressed_mb,pressure" > "$OUT"
echo "writing → $OUT  (Ctrl-C to stop)"

while true; do
  vm=$(vm_stat)
  page=$(echo "$vm" | awk '/page size of/ {print $8}')
  parse() { echo "$vm" | awk -v k="$1" -v p="$page" '$0 ~ k {gsub(/\./,"",$NF); printf "%.0f", $NF * p / 1048576}'; }
  pressure=$(memory_pressure 2>/dev/null | awk '/percentage/ {print $NF; exit}' || echo "")
  printf "%s,%s,%s,%s,%s,%s,%s\n" \
    "$(date -u +%FT%TZ)" \
    "$(parse 'Pages wired down')" \
    "$(parse 'Pages active')" \
    "$(parse 'Pages inactive')" \
    "$(parse 'Pages free')" \
    "$(parse 'Pages occupied by compressor')" \
    "$pressure" >> "$OUT"
  sleep 2
done
