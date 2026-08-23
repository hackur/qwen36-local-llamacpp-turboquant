#!/usr/bin/env bash
# Shared Qwen3.8 runtime helpers. This project intentionally supports one
# model family and one canonical pair of GGUF artifacts.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/configs/runtime.env"

MODEL_FILE="${MODEL_FILE:-$REPO/models/qwen38-27b.gguf}"
MMPROJ_FILE="${MMPROJ_FILE:-$REPO/models/qwen38-27b.mmproj.gguf}"
TURBOQUANT_BIN="${TURBOQUANT_BIN:-$REPO/vendor/llama-cpp-turboquant/build/bin/llama-server}"
MAINLINE_BIN="${MAINLINE_BIN:-$REPO/vendor/llama.cpp-mainline/build/bin/llama-server}"

SAMPLING=(
  --temp "$TEMP"
  --top-p "$TOP_P"
  --top-k "$TOP_K"
  --min-p "$MIN_P"
  --presence-penalty "$PRESENCE_PENALTY"
  --repeat-penalty "$REPEAT_PENALTY"
)

die() {
  echo "error: $*" >&2
  exit 1
}

print_help_from_header() {
  local file="${1:-${BASH_SOURCE[1]:-$0}}"
  awk '/^#!/{next} /^[^#]/{exit} {sub(/^# ?/,""); print}' "$file"
}

ensure_executable() {
  local path="$1" hint="$2"
  [[ -x "$path" ]] || die "$path is not executable ($hint)"
}

ensure_artifacts() {
  [[ -f "$MODEL_FILE" ]] || die "Qwen3.8 weights missing: $MODEL_FILE (run: make model-link)"
  [[ -f "$MMPROJ_FILE" ]] || die "Qwen3.8 projector missing: $MMPROJ_FILE (run: make model-link)"
}

ensure_port_free() {
  local port="$1" pids
  pids="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true)"
  [[ -z "$pids" ]] || die "port $port is already listening (pid(s): ${pids//$'\n'/,})"
}

ensure_no_other_llama_server() {
  [[ "${ALLOW_STACK:-0}" == "1" ]] && return 0
  local self_pid=$$ pids=() pid
  while read -r pid _; do
    [[ -z "$pid" || "$pid" == "$self_pid" ]] && continue
    pids+=("$pid")
  done < <(pgrep -lf llama-server 2>/dev/null || true)
  (( ${#pids[@]} == 0 )) || die "another llama-server is running (pid(s): ${pids[*]}); run make stop or set ALLOW_STACK=1"
}

server_help() {
  local bin="$1"
  "$bin" --help 2>&1 || true
}

require_help_flag() {
  local help="$1" flag="$2"
  grep -q -- "$flag" <<< "$help" || die "selected llama-server does not support $flag; run make upgrade"
}

append_runtime_features() {
  local bin_help="$1" mode="${2:-full}"

  RUNTIME_FLAGS=(
    -m "$MODEL_FILE"
    --mmproj "$MMPROJ_FILE"
    --image-min-tokens "$IMAGE_MIN_TOKENS"
    --port "$PORT"
    --host 127.0.0.1
    --cors-origins localhost
    --ctx-size "$CTX"
    --gpu-layers all
    --flash-attn on
    --parallel 1
    --jinja
    --reasoning auto
    --alias "$MODEL_NAME"
  )

  if [[ "$REASONING_PRESERVE" == "1" ]]; then
    require_help_flag "$bin_help" "--reasoning-preserve"
    RUNTIME_FLAGS+=(--reasoning-preserve)
  fi

  if [[ "$METRICS" == "1" ]]; then
    require_help_flag "$bin_help" "--metrics"
    RUNTIME_FLAGS+=(--metrics)
  fi

  if [[ "$AGENT" == "1" ]]; then
    require_help_flag "$bin_help" "--agent"
    RUNTIME_FLAGS+=(--agent)
  fi

  if [[ -n "$MCP_CONFIG" ]]; then
    [[ -r "$MCP_CONFIG" ]] || die "MCP_CONFIG is not readable: $MCP_CONFIG"
    require_help_flag "$bin_help" "--mcp-servers-config"
    RUNTIME_FLAGS+=(--mcp-servers-config "$MCP_CONFIG")
  fi

  if [[ "$mode" == "full" && "$MTP" == "1" ]]; then
    require_help_flag "$bin_help" "$MTP_TYPE"
    require_help_flag "$bin_help" "--spec-chain"
    RUNTIME_FLAGS+=(
      --spec-type "$MTP_TYPE"
      --spec-draft-n-min-adaptive "$MTP_MIN"
      --spec-draft-n-max "$MTP_MAX"
      --spec-chain "$MTP_CHAIN"
      --spec-draft-p-min "$MTP_P_MIN"
    )
  fi

  if [[ -n "$ROPE_SCALING" ]]; then
    [[ -n "$ROPE_SCALE" ]] || die "ROPE_SCALE is required when ROPE_SCALING is set"
    RUNTIME_FLAGS+=(
      --rope-scaling "$ROPE_SCALING"
      --rope-scale "$ROPE_SCALE"
      --yarn-orig-ctx "$YARN_ORIG_CTX"
    )
  fi

  RUNTIME_FLAGS+=("${SAMPLING[@]}")
}

print_command() {
  printf 'dry-run:'
  printf ' %q' "$@"
  printf '\n'
}

preflight_memory() {
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  local total_bytes model_bytes projector_bytes minimum_bytes
  total_bytes="$(sysctl -n hw.memsize)"
  model_bytes="$(stat -f %z "$MODEL_FILE")"
  projector_bytes="$(stat -f %z "$MMPROJ_FILE")"
  minimum_bytes=$((model_bytes + projector_bytes + 8 * 1024 * 1024 * 1024))
  (( total_bytes >= minimum_bytes )) || die "insufficient unified memory for Qwen3.8 Q8_0 + projector"
}
