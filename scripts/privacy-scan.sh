#!/usr/bin/env bash
# Public privacy scan: greps the tree for personal paths, names, hostnames,
# and credential-shaped strings. Exits non-zero on any match.
# Kept in sync with the same block in scripts/static-check.sh.
set -euo pipefail

case "${1:-}" in
  -h|--help) awk '/^#!/{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"; exit 0 ;;
esac
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

echo "Public privacy scan"
if git grep -n -E 'sarda|Jeremy Sarda|jcsarda@gmail\.com|/Users/you|/path/to/project|/path/to|Reference:|gh[ps]_[A-Za-z0-9]|sk-[A-Za-z0-9]{20,}|BEGIN (RSA|OPENSSH|PRIVATE)|PRIVATE KEY|Bearer [A-Za-z0-9._-]+' \
  -- . ':!scripts/static-check.sh' ':!scripts/privacy-scan.sh' ':!LICENSE' ':!docs/troubleshooting.md' >/tmp/qwen-privacy-scan.txt; then
  cat /tmp/qwen-privacy-scan.txt
  echo "  ✗ privacy scan found matches"
  exit 1
fi
echo "  ✓ no private path/name/token patterns found"
