#!/usr/bin/env bash
# Public privacy scan: checks the current tree and every commit reachable from
# main or a tag for private paths, identities, artifacts, and secrets.
set -euo pipefail

case "${1:-}" in
  -h|--help) awk '/^#!/{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$0"; exit 0 ;;
esac
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

SCAN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/qwen-privacy-scan.XXXXXX")"
trap 'rm -rf "$SCAN_DIR"' EXIT
PATTERN='jcsarda@gmail\.com|/Users/sarda|/Volumes/JS-DEV|~/Desktop|Local copy:|github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|xox[baprs]-[0-9A-Za-z-]{10,}|BEGIN (RSA|EC|DSA|OPENSSH|PGP) PRIVATE KEY|Bearer [A-Za-z0-9._=-]{12,}'

echo "Public privacy scan"

if git grep -n -I -E "$PATTERN" \
  -- . ':!scripts/static-check.sh' ':!scripts/privacy-scan.sh' ':!LICENSE' ':!docs/troubleshooting.md' \
  >"$SCAN_DIR/tree.txt"; then
  awk -F: '{print "  " $1 ":" $2 ":[REDACTED]"}' "$SCAN_DIR/tree.txt"
  echo "  ✗ current tree contains private data"
  exit 1
fi
echo "  ✓ current tree"

: >"$SCAN_DIR/history.txt"
git rev-list main --tags | while read -r commit; do
  git grep -n -I -E "$PATTERN" "$commit" \
    -- . ':!scripts/static-check.sh' ':!scripts/privacy-scan.sh' ':!LICENSE' ':!docs/troubleshooting.md' \
    >>"$SCAN_DIR/history.txt" || true
done
if [[ -s "$SCAN_DIR/history.txt" ]]; then
  awk -F: '{print "  " substr($1, 1, 12) ":" $2 ":" $3 ":[REDACTED]"}' \
    "$SCAN_DIR/history.txt" | sort -u
  echo "  ✗ reachable history contains private data"
  exit 1
fi
echo "  ✓ reachable file history"

git log main --tags --format='%H%x09%aE%x09%cE' | \
  awk -F '\t' 'tolower($2) == "jcsarda@gmail.com" || tolower($3) == "jcsarda@gmail.com" {print substr($1, 1, 12)}' \
  >"$SCAN_DIR/identities.txt"
if [[ -s "$SCAN_DIR/identities.txt" ]]; then
  sed 's/^/  /' "$SCAN_DIR/identities.txt"
  echo "  ✗ reachable commit metadata contains a personal email address"
  exit 1
fi
echo "  ✓ commit identities"

git rev-list main --tags --objects | cut -d' ' -f2- | \
  grep -E '(^|/)\.playwright-mcp/|(^|/)(\.env($|\.)|id_(rsa|ed25519)|.*\.(pem|key|p12|pfx|kdbx|sqlite|db|har|pcap))$' \
  >"$SCAN_DIR/artifacts.txt" || true
if [[ -s "$SCAN_DIR/artifacts.txt" ]]; then
  sed 's/^/  /' "$SCAN_DIR/artifacts.txt"
  echo "  ✗ reachable history contains private artifact paths"
  exit 1
fi
echo "  ✓ no private artifacts"

if command -v gitleaks >/dev/null 2>&1; then
  if ! gitleaks git "$REPO" --log-opts='main --tags' --redact=100 \
    --report-format=json --report-path="$SCAN_DIR/gitleaks.json" --no-banner --no-color \
    >/dev/null 2>&1; then
    if command -v jq >/dev/null 2>&1; then
      jq -r '.[] | "  \(.RuleID) \(.File):\(.StartLine) \(.Commit[0:12])"' \
        "$SCAN_DIR/gitleaks.json"
    fi
    echo "  ✗ gitleaks found credential-shaped content"
    exit 1
  fi
  echo "  ✓ gitleaks full-history scan"
else
  echo "  - gitleaks unavailable; built-in history checks passed"
fi
