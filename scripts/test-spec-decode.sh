#!/usr/bin/env bash
# test-spec-decode.sh — speculative-decoding A/B harness.
#
# Boots a TurboQuant llama-server with both a target model (-m) and a small
# draft model (--model-draft) so the target verifies tokens proposed by the
# draft in batch. The expectation: faster generation on memory-bandwidth-bound
# decodes when the draft's tokenizer matches the target's. See
# docs/speculative-decoding.md for the why and the gotchas.
#
# Usage:
#   DRAFT=models/draft.gguf ./scripts/test-spec-decode.sh
#   MODEL=qwen36-neo DRAFT=qwen3-0.6b PORT=10596 DRAFT_TOKENS=8 \
#       ./scripts/test-spec-decode.sh
#
# Runs scripts/bench.py against the new port once /health goes green, then
# tears the server down. Output: benchmarks/spec-decode-<ts>.md. Compare
# against the target-alone numbers in benchmarks/RESULTS.md (2026-05-07) or
# run the existing bench against your default :10501 server separately.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

case "${1:-}" in -h|--help) print_help_from_header; exit 0 ;; esac

MODEL_INPUT="${MODEL:-qwen36-neo}"
PORT="${PORT:-10596}"
DRAFT_TOKENS="${DRAFT_TOKENS:-8}"
COOLDOWN="${COOLDOWN:-15}"     # seconds idle before/after the run

if [[ -z "${DRAFT:-}" ]]; then
  echo "❌ DRAFT=<path-or-alias> is required (no default)."
  echo "   Examples:"
  echo "     DRAFT=models/draft.gguf  ./scripts/test-spec-decode.sh"
  echo "     DRAFT=qwen3-0.6b         ./scripts/test-spec-decode.sh"
  echo "   See docs/speculative-decoding.md for how to acquire a Qwen3-0.6B GGUF."
  exit 2
fi

BIN="$REPO/vendor/llama-cpp-turboquant/build/bin/llama-server"
LOG="$REPO/logs/spec-decode.log"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO/benchmarks/spec-decode-${TS}.md"

[[ -x "$BIN" ]] || { echo "❌ TurboQuant fork not built. Run scripts/build-llama.sh"; exit 1; }

# Resolve target.
resolve_model "$MODEL_INPUT"; TARGET="$RESOLVED_MODEL"; ensure_model "$TARGET"

# Resolve draft (alias under models/, or explicit path).
DRAFT_PATH="$DRAFT"
if [[ ! -f "$DRAFT_PATH" ]]; then
  if [[ -f "$REPO/models/${DRAFT}.gguf" ]]; then
    DRAFT_PATH="$REPO/models/${DRAFT}.gguf"
  else
    echo "❌ DRAFT not found at '$DRAFT' or '$REPO/models/${DRAFT}.gguf'"; exit 1
  fi
fi

# Probe binary for --model-draft. Older builds may lack it.
HELP_OUT=$("$BIN" -h 2>&1 || true)
if ! grep -q -- '--model-draft' <<< "$HELP_OUT"; then
  echo "❌ This llama-server build doesn't expose --model-draft."
  echo "   Rebuild the TurboQuant fork from a recent mainline merge (see"
  echo "   docs/upstream-tracking.md) or use vendor/llama.cpp-mainline."
  exit 3
fi

load_model_defaults "$MODEL_INPUT"
CTX="${CTX:-131072}"
KV="${KV:-turbo3}"
if ! grep -q -- "$KV" <<< "$HELP_OUT"; then
  echo "⚠  '$KV' not in build's --cache-type help. Falling back to q8_0."; KV=q8_0
fi
apply_kv_split

ensure_port_free "$PORT"
mkdir -p "$REPO/logs" "$REPO/benchmarks"

echo "▶ pre-run cooldown ${COOLDOWN}s + variance snapshot"
sleep "$COOLDOWN"
"$SCRIPT_DIR/diagnose-variance.sh" --tag "spec-pre-${TS}" >/dev/null || true

echo "▶ spec-decode @ http://127.0.0.1:$PORT"
echo "  target = $TARGET"
echo "  draft  = $DRAFT_PATH  (--draft $DRAFT_TOKENS)"
echo "  KV=${KV_K}/${KV_V}  CTX=${CTX}  log → $LOG"

TURBO_LAYER_ADAPTIVE=1 "$BIN" \
  -m "$TARGET" \
  --model-draft "$DRAFT_PATH" \
  --draft "$DRAFT_TOKENS" \
  --port "$PORT" \
  -c "$CTX" \
  -ctk "$KV_K" -ctv "$KV_V" \
  "${COMMON[@]}" \
  "${SAMPLING[@]}" \
  --alias qwen3.6-spec \
  >"$LOG" 2>&1 &
SERVER_PID=$!

cleanup() {
  if kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 1; done
    kill -0 "$SERVER_PID" 2>/dev/null && kill -KILL "$SERVER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# Wait for /health.
echo "  waiting for /health…"
for i in $(seq 1 180); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo "  /health OK after ${i}s"; break
  fi
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "❌ server died — see $LOG"; exit 4; }
  sleep 1
  if (( i == 180 )); then echo "❌ /health timeout — see $LOG"; exit 5; fi
done

# Bench against the new port.
LABEL="spec-decode (target=$(basename "$TARGET") draft=$(basename "$DRAFT_PATH") n=$DRAFT_TOKENS)"
BENCH_OUT="$(python3 "$SCRIPT_DIR/bench.py" "$PORT" "$LABEL" 2>&1 || true)"
echo "$BENCH_OUT"

# Post-run snapshot.
"$SCRIPT_DIR/diagnose-variance.sh" --tag "spec-post-${TS}" >/dev/null || true

# Report.
{
  echo "# Speculative-decoding run — $TS"
  echo
  echo "- target: \`$TARGET\`"
  echo "- draft:  \`$DRAFT_PATH\`"
  echo "- --draft $DRAFT_TOKENS"
  echo "- port: $PORT, CTX=$CTX, KV=${KV_K}/${KV_V}"
  echo
  echo "## bench.py output (target + draft)"
  echo
  echo '```'
  echo "$BENCH_OUT"
  echo '```'
  echo
  echo "## Baseline (target alone)"
  echo
  echo "Run \`python3 scripts/bench.py 10501 'target alone'\` against your default"
  echo "server, or compare against the qwen36-neo numbers in"
  echo "[\`benchmarks/RESULTS.md\`](RESULTS.md) (2026-05-07 entry)."
} > "$OUT"

echo "▶ wrote $OUT"
echo "▶ post-run cooldown ${COOLDOWN}s"
cleanup
trap - EXIT INT TERM
sleep "$COOLDOWN"
