#!/usr/bin/env bash
# Validate the complete local Qwen3.8 runtime without starting the model.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/scripts/_common.sh"
source "$REPO/configs/upstream.env"

fail=0
check_cmd() {
  local cmd="$1" hint="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    printf '  ok  %-10s %s\n' "$cmd" "$(command -v "$cmd")"
  else
    printf '  ERR %-10s %s\n' "$cmd" "$hint"
    fail=1
  fi
}
check_path() {
  local label="$1" path="$2" hint="$3"
  if [[ -e "$path" ]]; then
    printf '  ok  %-18s %s\n' "$label" "$path"
  else
    printf '  ERR %-18s %s\n' "$label" "$hint"
    fail=1
  fi
}
check_revision() {
  local label="$1" dir="$2" expected="$3" actual
  actual="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$actual" == "$expected" ]]; then
    printf '  ok  %-18s %s\n' "$label" "${actual:0:12}"
  else
    printf '  ERR %-18s expected %s, found %s (run: make build)\n' \
      "$label" "${expected:0:12}" "${actual:0:12}"
    fail=1
  fi
}

echo "Tools"
check_cmd git "install Xcode command-line tools"
check_cmd cmake "brew install cmake"
check_cmd curl "ships with macOS"
check_cmd jq "brew install jq"
check_cmd python3 "install Python 3.10+"
check_cmd node "install Node 20+"
check_cmd lsof "ships with macOS"

echo "Engines"
check_path "mainline source" "$REPO/vendor/llama.cpp-mainline/.git" "run: make build"
check_path "TurboQuant source" "$REPO/vendor/llama-cpp-turboquant/.git" "run: make build"
check_path "mainline server" "$MAINLINE_BIN" "run: make build"
check_path "TurboQuant server" "$TURBOQUANT_BIN" "run: make build"
check_revision "mainline revision" "$REPO/vendor/llama.cpp-mainline" "$LLAMA_CPP_SHA"
check_revision "TurboQuant revision" "$REPO/vendor/llama-cpp-turboquant" "$TURBOQUANT_SHA"

echo "Qwen3.8 artifacts"
check_path "Q8_0 weights" "$MODEL_FILE" "run: make model-link"
check_path "BF16 projector" "$MMPROJ_FILE" "run: make model-link"

if [[ -x "$TURBOQUANT_BIN" ]]; then
  help="$(server_help "$TURBOQUANT_BIN")"
  echo "Required TurboQuant features"
  for flag in turbo3 draft-mtp-adaptive --spec-chain --mmproj --image-min-tokens --reasoning-preserve --metrics --agent; do
    if grep -q -- "$flag" <<< "$help"; then
      printf '  ok  %s\n' "$flag"
    else
      printf '  ERR %s missing; run make upgrade\n' "$flag"
      fail=1
    fi
  done
fi

echo
if (( fail )); then
  echo "preflight failed"
else
  echo "preflight passed"
fi
exit "$fail"
