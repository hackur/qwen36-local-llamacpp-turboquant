#!/usr/bin/env bash
# Shared primary-runtime helpers. Model-specific defaults belong in profiles;
# independent experiments do not inherit Qwen-specific feature flags.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Source runtime.env once; a re-source is harmless (all values use := defaults).
if [[ ! -f "$REPO/configs/runtime.env" ]]; then
  echo "error: $REPO/configs/runtime.env not found" >&2
  return 1 2>/dev/null || exit 1
fi
source "$REPO/configs/runtime.env"

MODEL_FILE="${MODEL_FILE:-$REPO/models/qwen38-27b.gguf}"
MMPROJ_FILE="${MMPROJ_FILE-$REPO/models/qwen38-27b.mmproj.gguf}"
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
  [[ -f "$MODEL_FILE" ]] || die "model weights missing: $MODEL_FILE (run: make model-link or set MODEL_FILE)"
  # The vision projector is optional: text-only runs set MMPROJ_FILE="".
  [[ -z "$MMPROJ_FILE" || -f "$MMPROJ_FILE" ]] || die "projector missing: $MMPROJ_FILE (run: make model-link or set MMPROJ_FILE)"
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

  # Vision is only wired when a projector artifact is configured. Text-only
  # model profiles leave MMPROJ_FILE empty and the server runs without
  # multimodal input; --image-min-tokens is meaningless in that case.
  if [[ -n "$MMPROJ_FILE" ]]; then
    RUNTIME_FLAGS+=(
      --mmproj "$MMPROJ_FILE"
      --image-min-tokens "$IMAGE_MIN_TOKENS"
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
  projector_bytes=0
  [[ -n "$MMPROJ_FILE" ]] && projector_bytes="$(stat -f %z "$MMPROJ_FILE")"
  minimum_bytes=$((model_bytes + projector_bytes + 8 * 1024 * 1024 * 1024))
  (( total_bytes >= minimum_bytes )) || die "insufficient unified memory for $MODEL_FILE + projector"
}

# wait_for_health <port> [timeout_s=180] [path=/health]
# Poll http://127.0.0.1:<port><path> until it returns HTTP 200 or the timeout
# elapses. Returns 0 on healthy, 1 on timeout. Single canonical readiness wait
# so callers (switch-model.sh, service.sh, Makefile start, proxy.sh) stop each
# implementing their own loop with a different timeout/success criterion.
wait_for_health() {
  local port="$1" timeout_s="${2:-180}" path="${3:-/health}"
  local deadline=$(( $(date +%s) + timeout_s ))
  while (( $(date +%s) < deadline )); do
    if curl -sf --max-time 2 "http://127.0.0.1:${port}${path}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  return 1
}

# Shared two-phase kill loop (SIGTERM, wait, SIGKILL stragglers, re-scan in a
# bounded loop, then verify). $1 = a function name that prints the pids to kill
# (one per line; empty output means "none left"). Echoes what it did; returns 1
# if anything survived the final pass. stop-proxy.sh and stop-all.sh both call
# this so the kill discipline lives in exactly one place.
kill_pids_by() {
  local lister="$1" max_passes="${2:-5}" pids=() pid cmd found_any=0
  for ((pass=1; pass<=max_passes; pass++)); do
    pids=()
    while IFS= read -r pid; do [[ -n "$pid" ]] && pids+=("$pid"); done < <("$lister")
    (( ${#pids[@]} == 0 )) && break
    found_any=1
    for pid in "${pids[@]}"; do
      cmd="$(ps -p "$pid" -o command= 2>/dev/null | head -c 120)"
      echo "  [pass $pass] kill $pid : $cmd"
      kill "$pid" 2>/dev/null || true
    done
    sleep 2
    for pid in "${pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        echo "  [pass $pass] SIGKILL $pid (didn't exit gracefully)"
        kill -9 "$pid" 2>/dev/null || true
      fi
    done
  done
  if (( found_any == 0 )); then
    echo "  (no matching processes were running)"
    return 0
  fi
  local remaining=()
  while IFS= read -r pid; do [[ -n "$pid" ]] && remaining+=("$pid"); done < <("$lister")
  if (( ${#remaining[@]} > 0 )); then
    echo "❌ survivors after $max_passes passes — investigate manually:" >&2
    for pid in "${remaining[@]}"; do
      ps -p "$pid" -o pid=,ppid=,command= 2>/dev/null >&2
    done
    return 1
  fi
  echo "  ✓ all stopped"
  return 0
}

# list_pids_by_port <port> — pids listening on a TCP port, one per line.
list_pids_by_port() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null || true
}

# list_pids_by_repo_cmd — pids whose full command line mentions any of the repo
# llama-server build paths. Uses ps (not pgrep) because the llama-server command
# line exceeds pgrep's scan limit (see stop-all.sh).
list_pids_by_repo_cmd() {
  local repo="$REPO"
  /bin/ps -axww -o pid=,command= | awk -v repo="$repo" '
    index($0, repo "/vendor/llama.cpp-mainline/build/bin/llama-server")     { print $1 }
    index($0, repo "/vendor/llama-cpp-turboquant/build/bin/llama-server")    { print $1 }
  ' | sort -u
}

log_stamp() {
  date +%Y-%m-%d-%H-%M-%S
}

timestamp_logs() {
  perl -MPOSIX -ne '$|=1; print strftime("%Y-%m-%d-%H-%M-%S", localtime), " $_"'
}

log_banner() {
  echo "=== $(log_stamp) $* ==="
}
