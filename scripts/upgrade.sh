#!/usr/bin/env bash
# Safely git-pull both forks and rebuild. Shows incoming commits before pulling
# so you can decide whether to upgrade.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

upgrade_one() {
  local name="$1" dir="$2"
  echo "── $name ──"
  if [[ ! -d "$dir/.git" ]]; then echo "  (not a git checkout, skipping)"; return; fi
  ( cd "$dir"
    git fetch --depth 50 origin 2>&1 | sed 's/^/  /'
    local branch; branch=$(git rev-parse --abbrev-ref HEAD)
    local local_sha remote_sha
    local_sha=$(git rev-parse HEAD)
    remote_sha=$(git rev-parse origin/"$branch" 2>/dev/null || echo "$local_sha")
    if [[ "$local_sha" == "$remote_sha" ]]; then echo "  ✓ already up to date"; return; fi
    echo "  incoming commits ($branch):"
    git log --oneline "$local_sha..$remote_sha" | head -20 | sed 's/^/    /'
  )
  read -r -p "  Pull and rebuild $name? [y/N] " ans
  if [[ "${ans,,}" == "y" ]]; then
    ( cd "$dir" && git pull --ff-only )
    rm -rf "$dir/build"
    echo "  rebuilding…"
    "$REPO/scripts/build-llama.sh"
  else
    echo "  (skipped)"
  fi
}

upgrade_one "mainline"   "$REPO/vendor/llama.cpp-mainline"
upgrade_one "turboquant" "$REPO/vendor/llama-cpp-turboquant"
echo
echo "Done. Verify with: scripts/healthcheck.sh && scripts/quality-check.sh"
