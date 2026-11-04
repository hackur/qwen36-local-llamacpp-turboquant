#!/usr/bin/env bash
# Show the model servers, optional compaction proxy, and classifier gate.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/scripts/_common.sh"   # provides PORT, PORT_BASELINE, PORT_PROXY, PORT_LAYA

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

probe "$PORT" "Qwen3.8 full runtime"
probe "$PORT_BASELINE" "Qwen3.8 baseline"

printf '%-28s :%-5s ' "Compaction proxy" "$PORT_PROXY"
if proxy_info="$(curl -sf --max-time 1 http://127.0.0.1:$PORT_PROXY/proxy/info 2>/dev/null)"; then
  proxy_pid="$(lsof -nP -iTCP:$PORT_PROXY -sTCP:LISTEN -t 2>/dev/null | head -1)"
  proxy_mode="$(jq -r '.mode // "?"' <<< "$proxy_info")"
  jev_enabled="$(jq -r '.jev.enabled // false' <<< "$proxy_info")"
  echo "up pid=$proxy_pid mode=$proxy_mode jev=$jev_enabled"
else
  echo "down"
fi

printf '%-28s :%-5s ' "Laya classifier" "$PORT_LAYA"
if laya_info="$(curl -sf --max-time 3 http://127.0.0.1:$PORT_LAYA/health 2>/dev/null)"; then
  echo "up $(jq -c '{loaded,device}' <<< "$laya_info")"
else
  echo "down"
fi
