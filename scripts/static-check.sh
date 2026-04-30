#!/usr/bin/env bash
# Static checks that do not build, download models, or start servers.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

echo "Shell syntax"
for f in scripts/*.sh Qwen-Offline.command; do
  bash -n "$f"
  printf "  ✓ %s\n" "$f"
done

echo
echo "Makefile help"
make help >/dev/null
echo "  ✓ make help"

echo
echo "Public privacy scan"
if git grep -n -E 'sarda|Jeremy Sarda|jcsarda@gmail\.com|/Users/sarda|/Volumes/JS-DEV|~/Desktop|Local copy:|gh[ps]_[A-Za-z0-9]|sk-[A-Za-z0-9]{20,}|BEGIN (RSA|OPENSSH|PRIVATE)|PRIVATE KEY|Bearer [A-Za-z0-9._-]+' \
  -- . ':!scripts/static-check.sh' >/tmp/qwen-static-privacy.txt; then
  cat /tmp/qwen-static-privacy.txt
  echo "  ✗ privacy scan found matches"
  exit 1
fi
echo "  ✓ no private path/name/token patterns found"

echo
echo "Static checks passed"
