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
echo "Python syntax"
for f in scripts/*.py; do
  python3 -m py_compile "$f"
  printf "  ✓ %s\n" "$f"
done

echo
echo "Python tests"
python3 -m unittest discover -s tests >/tmp/qwen-static-tests.log 2>&1 \
  && printf "  ✓ %s\n" "$(grep -E '^Ran [0-9]+ test' /tmp/qwen-static-tests.log | tail -1)" \
  || { tail -40 /tmp/qwen-static-tests.log; echo "  ✗ unittest failures"; exit 1; }

echo
echo "Makefile help"
make help >/dev/null
echo "  ✓ make help"

echo
./scripts/privacy-scan.sh

echo
echo "Static checks passed"
