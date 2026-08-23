#!/usr/bin/env bash
# Update both ignored vendor checkouts to their current upstream branch tips,
# rebuild, and print the exact revisions that should be committed as verified.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/configs/upstream.env"

upgrade_one() {
  local name="$1" dir="$2" branch="$3"
  echo "── $name ($branch) ──"
  [[ -d "$dir/.git" ]] || { echo "❌ missing checkout: $dir"; return 1; }
  [[ -z "$(git -C "$dir" status --porcelain)" ]] || {
    echo "❌ vendor checkout is dirty; refusing to replace its branch" >&2
    git -C "$dir" status --short >&2
    return 1
  }
  # Each shallow vendor checkout already maps its accepted branch to the
  # matching origin-tracking ref. Passing the same destination refspec again
  # can make newer Git releases prune and recreate that ref in one fetch.
  git -C "$dir" fetch --prune origin "$branch"
  git -C "$dir" switch -C "$branch" "origin/$branch"
  git -C "$dir" log -1 --format='  ✓ %H %cs %s'
}

upgrade_one "llama.cpp" "$REPO/vendor/llama.cpp-mainline" "$LLAMA_CPP_BRANCH"
upgrade_one "TurboQuant" "$REPO/vendor/llama-cpp-turboquant" "$TURBOQUANT_BRANCH"

# Candidate mode is the sole exception to build-llama.sh's accepted-pin
# enforcement. The exact candidate revisions are printed below and become
# normal build inputs only after local validation updates upstream.env.
CANDIDATE=1 FORCE=1 "$REPO/scripts/build-llama.sh"

echo
echo "Verified revisions:"
printf '  LLAMA_CPP_SHA=%s\n' "$(git -C "$REPO/vendor/llama.cpp-mainline" rev-parse HEAD)"
printf '  TURBOQUANT_SHA=%s\n' "$(git -C "$REPO/vendor/llama-cpp-turboquant" rev-parse HEAD)"
echo "Run make check, then update configs/upstream.env if these differ."
