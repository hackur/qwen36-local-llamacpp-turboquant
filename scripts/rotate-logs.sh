#!/usr/bin/env bash
# Rotate llama-server logs. Keeps last 7 days. Run from cron or launchd, or by hand.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGDIR="$REPO/logs"
KEEP_DAYS="${KEEP_DAYS:-7}"

[[ -d "$LOGDIR" ]] || { echo "no logs/ dir"; exit 0; }

# 1. Compress logs older than 1 day that aren't already compressed.
find "$LOGDIR" -type f -name "*.log" -mtime +0 ! -name "*.gz" -print -exec gzip -9 {} \;

# 2. Delete compressed logs older than KEEP_DAYS.
find "$LOGDIR" -type f -name "*.log.gz" -mtime "+$KEEP_DAYS" -print -delete

# 3. Truncate the active turboquant.log if larger than 100 MB (server keeps appending while running).
for f in "$LOGDIR/turboquant.log" "$LOGDIR/baseline.log"; do
  [[ -f "$f" ]] || continue
  size=$(stat -f %z "$f" 2>/dev/null || echo 0)
  if (( size > 100*1024*1024 )); then
    cp "$f" "$f.$(date +%Y%m%d-%H%M%S).log"
    : > "$f"
    echo "  truncated $f (was $((size/1024/1024)) MB)"
  fi
done

echo "✓ rotated"
ls -lh "$LOGDIR"/ | tail -n +2
