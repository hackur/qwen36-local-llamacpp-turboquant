#!/usr/bin/env bash
# Check local prerequisites without building or starting a model.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail=0

check_cmd() {
  local cmd="$1" hint="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "  ✓ %-12s %s\n" "$cmd" "$(command -v "$cmd")"
  else
    printf "  ✗ %-12s missing (%s)\n" "$cmd" "$hint"
    fail=1
  fi
}

check_path() {
  local label="$1" path="$2" hint="$3"
  if [[ -e "$path" ]]; then
    printf "  ✓ %-18s %s\n" "$label" "$path"
  else
    printf "  ! %-18s missing (%s)\n" "$label" "$hint"
  fi
}

echo "Tools"
check_cmd git "install Xcode command line tools"
check_cmd cmake "brew install cmake"
check_cmd make "install Xcode command line tools"
check_cmd curl "ships with macOS"
check_cmd jq "brew install jq"
check_cmd python3 "install Xcode command line tools or python.org"
check_cmd lsof "ships with macOS"

if [[ "$(uname -s)" == "Darwin" ]]; then
  if xcode-select -p >/dev/null 2>&1; then
    printf "  ✓ %-12s %s\n" "xcode" "$(xcode-select -p)"
  else
    printf "  ✗ %-12s missing (run: xcode-select --install)\n" "xcode"
    fail=1
  fi
else
  printf "  ! %-12s this project is tuned for macOS + Apple Metal\n" "platform"
fi

echo
echo "Checkouts"
check_path "mainline source" "$REPO/vendor/llama.cpp-mainline/.git" "run: make build"
check_path "turboquant source" "$REPO/vendor/llama-cpp-turboquant/.git" "run: make build"
check_path "mainline server" "$REPO/vendor/llama.cpp-mainline/build/bin/llama-server" "run: make build"
check_path "turboquant server" "$REPO/vendor/llama-cpp-turboquant/build/bin/llama-server" "run: make build"

echo
echo "Models"
shopt -s nullglob
models=("$REPO"/models/*.gguf)
weights=()
for f in "${models[@]}"; do
  [[ "$(basename "$f")" == *.mmproj.gguf ]] && continue
  weights+=("$f")
done
if (( ${#weights[@]} == 0 )); then
  echo "  ! no model symlinks found (run: ./scripts/symlink-models.sh, or pass MODEL=/path/to/model.gguf)"
else
  for f in "${weights[@]}"; do
    if [[ -e "$f" ]]; then
      printf "  ✓ %s\n" "${f#$REPO/}"
    else
      printf "  ✗ %s -> broken symlink\n" "${f#$REPO/}"
      fail=1
    fi
  done
fi

echo
if (( fail == 0 )); then
  echo "preflight passed"
else
  echo "preflight found missing required items"
fi
exit "$fail"
