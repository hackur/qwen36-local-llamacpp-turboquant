#!/usr/bin/env bash
# Shared env for start scripts.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Primary alias — Qwen 3.6 27B Heretic-Uncensored NEO-CODE Q5_K_M (~19.5 GB dense, 256K n_ctx_train).
# Resolves to ./models/qwen36-neo.gguf via symlink-models.sh.
MODEL_PRIMARY="$REPO/models/qwen36-neo.gguf"
MMPROJ_PRIMARY="$REPO/models/qwen36-neo.mmproj.gguf"

# Fallback — Qwen3.6-35B-A3B Q6_K (MoE, prior default). 27B IQ2_XXS still available as `qwen36-27b`.
MODEL_FALLBACK="$REPO/models/qwen36-35b.gguf"
MMPROJ_FALLBACK="$REPO/models/qwen36-35b.mmproj.gguf"

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

# port-guard:v1 — abort if $1 is already bound by a LISTEN socket.
# Uses lsof (local-only, no network) so this stays offline-safe.
# LM Studio commonly squats on :1234; our servers use 10500/10501/10502/10503.
ensure_port_free() {
  local port="$1"
  local pids
  pids="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true)"
  if [[ -n "$pids" ]]; then
    echo "❌ Port $port already in use. Is LM Studio's server (default :1234) or another llama-server running?" >&2
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >&2 || true
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

# help-from-header:v1 — print the script's leading `#`-comment block as usage.
# Strips the shebang and the leading `# ` from each line; stops at the first
# non-comment line. Use as:
#     case "${1:-}" in -h|--help) print_help_from_header; exit 0 ;; esac
# right after sourcing _common.sh, so `--help` never triggers any side effects
# (e.g. accidentally launching llama-server).
print_help_from_header() {
  local f="${1:-${BASH_SOURCE[1]:-$0}}"
  awk '/^#!/{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$f"
}

# load_model_defaults <alias-or-path>
#   Sources configs/model-defaults.env with MODEL_ALIAS exported, so the
#   case statement there can set CTX/KV/ROPE_* via `: "${VAR:=...}"`.
#   Anything already in the environment wins; per-model defaults fill the rest.
#   Path inputs (containing "/" or ending .gguf) skip per-alias defaults and
#   only get the generic block — pass MODEL_ALIAS=foo if you want a specific
#   per-alias entry to apply to a literal path.
load_model_defaults() {
  local in="$1"
  if [[ "$in" == */* || "$in" == *.gguf ]]; then
    MODEL_ALIAS="${MODEL_ALIAS:-}"
  else
    MODEL_ALIAS="${MODEL_ALIAS:-$in}"
  fi
  local f="$REPO/configs/model-defaults.env"
  if [[ -r "$f" ]]; then
    # shellcheck disable=SC1090
    source "$f"
  fi
}

# mixed-kv-guard:v1 — warn on mismatched K vs V cache types.
# Mixed K/V cache types (e.g. -ctk q8_0 -ctv f16) trigger ~50% slower attention
# than matched types — see HANDOFF.md / docs/troubleshooting.md.
# Env contract:
#   KV    — applied to both K and V unless overridden (default source-of-truth)
#   KV_K  — overrides K only
#   KV_V  — overrides V only
# Sets KV_K and KV_V in the current shell. Callers should pass
# `-ctk "$KV_K" -ctv "$KV_V"` after invoking this. If KV_K != KV_V, prints a
# stderr warning unless MIXED_KV_OK=1 is set.
apply_kv_split() {
  KV_K="${KV_K:-$KV}"
  KV_V="${KV_V:-$KV}"
  if [[ "$KV_K" != "$KV_V" && "${MIXED_KV_OK:-0}" != "1" ]]; then
    echo "⚠️  Mixed K/V cache types: -ctk $KV_K vs -ctv $KV_V" >&2
    echo "    Mismatched K/V types are ~50% slower than matched (see docs/troubleshooting.md)." >&2
    echo "    Set KV=<type> to match both, or MIXED_KV_OK=1 to silence this warning." >&2
  fi
}

# rope_args — emit llama-server flags for YaRN scaling, or nothing.
#   Reads ROPE_SCALING, ROPE_SCALE, YARN_ORIG_CTX from the environment.
#   Use:  ROPE_FLAGS=( $(rope_args) )  ;  ${BIN} ... "${ROPE_FLAGS[@]}"
rope_args() {
  if [[ -n "${ROPE_SCALING:-}" ]]; then
    printf -- "--rope-scaling %s " "$ROPE_SCALING"
    [[ -n "${ROPE_SCALE:-}" ]]    && printf -- "--rope-scale %s "    "$ROPE_SCALE"
    [[ -n "${YARN_ORIG_CTX:-}" ]] && printf -- "--yarn-orig-ctx %s " "$YARN_ORIG_CTX"
  fi
}
