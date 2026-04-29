#!/usr/bin/env bash
# Shared env for start scripts.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Primary alias — `qwen36-35b` resolves to ./models/qwen36-35b.gguf via symlink-models.sh
MODEL_PRIMARY="$REPO/models/qwen36-35b.gguf"
MMPROJ_PRIMARY="$REPO/models/qwen36-35b.mmproj.gguf"

# Fallback — Qwen3.6-27B IQ2_XXS
MODEL_FALLBACK="$REPO/models/qwen36-27b.gguf"
MMPROJ_FALLBACK="$REPO/models/qwen36-27b.mmproj.gguf"

# resolve_model <alias-or-path>
#   Sets RESOLVED_MODEL and RESOLVED_MMPROJ in the *current* shell (no subshell capture).
#   If the input contains "/" or ".gguf", it's already a path — pass through.
#   Otherwise look up models/<alias>.gguf.
resolve_model() {
  local in="$1"
  RESOLVED_MMPROJ=""
  if [[ "$in" == */* || "$in" == *.gguf ]]; then
    RESOLVED_MODEL="$in"
    if [[ -f "${in%.gguf}.mmproj.gguf" ]]; then RESOLVED_MMPROJ="${in%.gguf}.mmproj.gguf"; fi
    return 0
  fi
  local p="$REPO/models/$in.gguf"
  if [[ ! -f "$p" ]]; then
    echo "❌ Unknown model alias '$in'. Available:" >&2
    list_aliases >&2
    echo "  (or pass MODEL=/full/path/to/file.gguf)" >&2
    exit 1
  fi
  RESOLVED_MODEL="$p"
  if [[ -f "$REPO/models/$in.mmproj.gguf" ]]; then RESOLVED_MMPROJ="$REPO/models/$in.mmproj.gguf"; fi
  return 0   # explicit — trailing `[[ ]] && ...` returns 1 if test is false, which `set -e` would catch
}

# list_aliases — print just the alias names (one per line), no mmproj.
list_aliases() {
  for f in "$REPO/models"/*.gguf; do
    [[ -e "$f" ]] || continue
    local n; n=$(basename "$f" .gguf)
    [[ "$n" == *.mmproj ]] && continue
    echo "  $n"
  done
}

# Sampling per Qwen team recommendations (thinking/coding)
SAMPLING=(--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0)

# Common server args.
# --jinja enables Qwen 3.6's chat template (which supports the
# `chat_template_kwargs.enable_thinking` flag clients pass per-request).
# --reasoning-format none keeps thinking content inline so callers see it
# even when default-on; clients can flip it off per-request.
COMMON=(-ngl 99 -fa on -np 1 --host 127.0.0.1 --jinja)

ensure_port_free() {
  local port="$1"
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "❌ Port $port already in use. Is LM Studio's server (default :1234) or another llama-server running?"
    lsof -nP -iTCP:"$port" -sTCP:LISTEN
    exit 1
  fi
}

ensure_model() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "❌ Model missing: $path"
    echo "   Open LM Studio → Models tab to download, or fix the path."
    exit 1
  fi
}
