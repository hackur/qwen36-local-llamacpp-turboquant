#!/usr/bin/env bash
# Start TurboQuant server with the multimodal projector loaded (vision-capable).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

PORT="${PORT:-10503}"
CTX="${CTX:-32768}"
MODEL_INPUT="${MODEL:-qwen36-35b}"
KV="${KV:-turbo3}"
BIN="$REPO/vendor/llama-cpp-turboquant/build/bin/llama-server"
LOG="$REPO/logs/vision.log"

[[ -x "$BIN" ]] || { echo "❌ TurboQuant fork not built"; exit 1; }
resolve_model "$MODEL_INPUT"
MODEL="$RESOLVED_MODEL"
ensure_model "$MODEL"
MMPROJ="${MMPROJ:-${RESOLVED_MMPROJ:-}}"
if [[ -z "$MMPROJ" || ! -f "$MMPROJ" ]]; then
  echo "❌ No mmproj for '$MODEL_INPUT'. Pick a multimodal model:"
  ls "$REPO/models/"*.mmproj.gguf 2>/dev/null | sed 's/.mmproj.gguf$//; s|.*/||; s/^/  /'
  exit 1
fi
ensure_model "$MMPROJ"
ensure_port_free "$PORT"

# memory-preflight:v1 — vision combos (text server on :10501 + this on :10503)
# can OOM a 64 GB box. Sum: model GGUF size + mmproj size + KV/scratch margin
# + RSS of any other running llama-server processes + 4 GiB headroom, and
# bail if that exceeds physical RAM. Override with FORCE=1.
preflight_memory() {
  local model="$1" mmproj="$2"
  local model_bytes mmproj_bytes total_bytes
  model_bytes=$(stat -f%z "$model" 2>/dev/null || echo 0)
  mmproj_bytes=$(stat -f%z "$mmproj" 2>/dev/null || echo 0)
  total_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  if [[ "$total_bytes" -le 0 ]]; then return 0; fi  # unknown — skip
  local kv_scratch_bytes=$((1536 * 1024 * 1024))    # ~1.5 GiB KV/scratch margin
  local headroom_bytes=$((4096 * 1024 * 1024))      # 4 GiB OS headroom

  # Sum RSS (KiB on macOS) of other already-running llama-server processes.
  local other_rss_kib=0 pid rss self_pid=$$
  while read -r pid _; do
    [[ -z "$pid" || "$pid" == "$self_pid" ]] && continue
    rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -n "$rss" ]] && other_rss_kib=$((other_rss_kib + rss))
  done < <(pgrep -lf llama-server 2>/dev/null || true)
  local other_rss_bytes=$((other_rss_kib * 1024))

  local need_bytes=$((model_bytes + mmproj_bytes + kv_scratch_bytes + other_rss_bytes + headroom_bytes))
  local gib=$((1024 * 1024 * 1024))
  local need_gib=$((need_bytes / gib))
  local total_gib=$((total_bytes / gib))
  local free_gib=$(((total_bytes - other_rss_bytes) / gib))

  if [[ "$need_bytes" -gt "$total_bytes" ]]; then
    echo "⚠️  Memory pre-flight: '$(basename "$model")' + mmproj needs ~${need_gib} GiB" >&2
    echo "    (model $((model_bytes/gib)) GiB + mmproj $((mmproj_bytes/gib)) GiB + 1.5 GiB KV + $((other_rss_bytes/gib)) GiB other llama-server RSS + 4 GiB headroom)" >&2
    echo "    System has ${total_gib} GiB physical, ~${free_gib} GiB available after other servers." >&2
    if [[ "${FORCE:-0}" != "1" ]]; then
      echo "    Refusing to start. Set FORCE=1 to override, or stop the other llama-server first." >&2
      exit 1
    fi
    echo "    FORCE=1 set — proceeding anyway." >&2
  fi
}
preflight_memory "$MODEL" "$MMPROJ"

mkdir -p "$REPO/logs"

if ! "$BIN" -h 2>&1 | grep -q -- "$KV"; then KV=q8_0; fi

# mixed-kv-guard:v1 — derive KV_K / KV_V from KV (unless overridden) and warn on mismatch.
apply_kv_split

KV_DESC="$KV_K"; [[ "$KV_K" != "$KV_V" ]] && KV_DESC="${KV_K}/${KV_V}"
echo "▶ vision @ http://127.0.0.1:$PORT  (KV=$KV_DESC, ${CTX} ctx, mmproj loaded)"
TURBO_LAYER_ADAPTIVE=1 exec "$BIN" \
  -m "$MODEL" \
  --mmproj "$MMPROJ" \
  --port "$PORT" \
  -c "$CTX" \
  -ctk "$KV_K" -ctv "$KV_V" \
  "${COMMON[@]}" \
  "${SAMPLING[@]}" \
  --alias qwen3.6-vision \
  2>&1 | tee "$LOG"
