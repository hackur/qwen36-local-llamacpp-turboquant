#!/usr/bin/env bash
# Start the small summarizer llama-server on :10503.
#
# This is the second model the compaction proxy talks to out-of-band
# (see docs/compaction-strategy.md §4). The primary 35B keeps generating
# while the summarizer rewrites evicted prose.
#
# Defaults to gemma4-e4b. Override via SUMMARIZER_MODEL=<alias-or-path>.
# Pass --cpu-only to run without GPU offload (frees VRAM for the primary).
# Pass --dry-run to print the command without exec'ing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Reuse repo helpers if available.
if [[ -f "$REPO/scripts/_common.sh" ]]; then
  # shellcheck disable=SC1091
  source "$REPO/scripts/_common.sh"
fi

DRY_RUN=0
CPU_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)  DRY_RUN=1 ;;
    --cpu-only) CPU_ONLY=1 ;;
    -h|--help)
      cat <<EOF
Usage: start-summarizer.sh [--cpu-only] [--dry-run]

Env:
  SUMMARIZER_MODEL   alias (e.g. gemma4-e4b, nemotron-4b, tiny) or .gguf path
                     default: gemma4-e4b
  PORT               listen port (default 10503)
  CTX                context size (default 16384)
  NGL                GPU layers when not --cpu-only (default 99)
EOF
      exit 0
      ;;
  esac
done

PORT="${PORT:-10503}"
CTX="${CTX:-16384}"
NGL="${NGL:-99}"
MODEL_INPUT="${SUMMARIZER_MODEL:-gemma4-e4b}"

BIN="$REPO/vendor/llama-cpp-turboquant/build/bin/llama-server"
LOG_DIR="${HOME}/.cache/qwen-compact/logs"
LOG="$LOG_DIR/summarizer.log"
mkdir -p "$LOG_DIR"

if [[ ! -x "$BIN" ]]; then
  echo "llama-server binary not found or not executable: $BIN" >&2
  echo "Run scripts/build-llama.sh first." >&2
  exit 1
fi

# Resolve model. Prefer the helper from _common.sh; fall back to direct path.
if declare -f resolve_model >/dev/null 2>&1; then
  resolve_model "$MODEL_INPUT"
  MODEL="$RESOLVED_MODEL"
else
  if [[ "$MODEL_INPUT" == */* || "$MODEL_INPUT" == *.gguf ]]; then
    MODEL="$MODEL_INPUT"
  else
    MODEL="$REPO/models/$MODEL_INPUT.gguf"
  fi
fi

if [[ ! -f "$MODEL" ]]; then
  echo "Summarizer model missing: $MODEL" >&2
  echo "Set SUMMARIZER_MODEL or download into models/. See README." >&2
  exit 1
fi

# Idempotency: if something is already on PORT, exit cleanly.
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "summarizer already listening on :$PORT — leaving it alone."
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN || true
  exit 0
fi

# GPU offload: 0 layers means CPU-only.
if (( CPU_ONLY )); then
  GPU_LAYERS=0
else
  GPU_LAYERS="$NGL"
fi

# Args mirror scripts/start-turboquant.sh conventions where they apply
# (single slot, host 127.0.0.1, jinja templates, flash attention on GPU).
ARGS=(
  -m "$MODEL"
  --port "$PORT"
  --host 127.0.0.1
  -c "$CTX"
  -ngl "$GPU_LAYERS"
  -np 1
  --jinja
  --alias qwen-compact-summarizer
)
# Flash-attention is GPU-only in this build; skip on CPU.
if ! (( CPU_ONLY )); then
  ARGS+=(-fa on)
fi

echo "summarizer @ http://127.0.0.1:$PORT  (model=$(basename "$MODEL"), ctx=$CTX, gpu_layers=$GPU_LAYERS)"
echo "log -> $LOG"

if (( DRY_RUN )); then
  printf "dry-run:"
  printf " %q" "$BIN" "${ARGS[@]}"
  printf " 2>&1 | tee -a %q\n" "$LOG"
  exit 0
fi

exec "$BIN" "${ARGS[@]}" 2>&1 | tee -a "$LOG"
