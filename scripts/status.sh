#!/usr/bin/env bash
# Show the two deliberate Qwen3.8 runtime modes: full TurboQuant and baseline.
set -uo pipefail

probe() {
  local port="$1" label="$2"
  printf '%-28s :%-5s ' "$label" "$port"
  if ! curl -sf --max-time 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
    echo "down"
    return
  fi
  local pid model
  pid="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)"
  model="$(curl -sf --max-time 1 "http://127.0.0.1:$port/v1/models" | jq -r '.data[0].id // "?"')"
  echo "up pid=$pid model=$model"
}

probe 10501 "Qwen3.8 full runtime"
probe 10500 "Qwen3.8 baseline"
