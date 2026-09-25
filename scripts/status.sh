#!/usr/bin/env bash
# Show the model servers, optional compaction proxy, and classifier gate.
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

printf '%-28s :%-5s ' "Compaction proxy" "11500"
if proxy_info="$(curl -sf --max-time 1 http://127.0.0.1:11500/proxy/info 2>/dev/null)"; then
  proxy_pid="$(lsof -nP -iTCP:11500 -sTCP:LISTEN -t 2>/dev/null | head -1)"
  proxy_mode="$(jq -r '.mode // "?"' <<< "$proxy_info")"
  jev_enabled="$(jq -r '.jev.enabled // false' <<< "$proxy_info")"
  echo "up pid=$proxy_pid mode=$proxy_mode jev=$jev_enabled"
else
  echo "down"
fi
