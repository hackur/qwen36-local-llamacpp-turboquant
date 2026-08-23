#!/usr/bin/env bash
# Report the canonical Qwen3.8 weights and vision projector.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/scripts/_common.sh"

show_artifact() {
  local label="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    printf '%-12s missing (%s)\n' "$label" "$path"
    return 1
  fi
  local real size
  real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$path")"
  size="$(du -h "$real" | awk '{print $1}')"
  printf '%-12s %-8s %s\n' "$label" "$size" "$real"
}

echo "Qwen3.8-27B Q8_0 (only supported model)"
show_artifact "weights" "$MODEL_FILE"
show_artifact "projector" "$MMPROJ_FILE"
echo "context      $CTX native tokens"
echo "runtime      q8_0/turbo3 KV + adaptive chained MTP + vision + agent tools"
