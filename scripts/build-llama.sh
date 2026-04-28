#!/usr/bin/env bash
# Build mainline llama.cpp + TurboQuant fork with Apple Metal.
# Idempotent: skips builds whose binaries already exist unless FORCE=1.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="$(sysctl -n hw.ncpu)"
FORCE="${FORCE:-0}"

build_one() {
  local name="$1" dir="$2"
  local bin="$dir/build/bin/llama-server"

  if [[ ! -d "$dir" ]]; then
    echo "❌ $name not cloned at $dir"
    return 1
  fi

  if [[ -x "$bin" && "$FORCE" != "1" ]]; then
    echo "✓ $name already built ($bin) — set FORCE=1 to rebuild"
    return 0
  fi

  echo "▶ Building $name in $dir"
  cd "$dir"
  cmake -B build \
    -DGGML_METAL=ON \
    -DGGML_NATIVE=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_BUILD_SERVER=ON
  cmake --build build -j"$JOBS" --target llama-server llama-cli llama-bench
  echo "✓ $name built → $bin"
}

build_one "mainline"    "$REPO/vendor/llama.cpp-mainline"
build_one "turboquant"  "$REPO/vendor/llama-cpp-turboquant"

echo
echo "── TurboQuant flag check ──"
"$REPO/vendor/llama-cpp-turboquant/build/bin/llama-server" -h 2>&1 | grep -E 'turbo[234]|cache.type' || \
  echo "⚠  No turbo[234] in help output — fork may not have built TurboQuant. Falling back to q8_0 KV cache is supported."
