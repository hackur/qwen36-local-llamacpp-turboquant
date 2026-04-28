#!/usr/bin/env bash
# Show what's running, on which ports, with which model.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

probe() {
  local port="$1" label="$2"
  printf "── %s :%s\n" "$label" "$port"
  if curl -sf --max-time 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
    local model
    model=$(curl -s "http://127.0.0.1:$port/v1/models" 2>/dev/null \
      | python3 -c "import sys,json; r=json.load(sys.stdin); m=r.get('data',[{}])[0]; print(m.get('id','?'))" 2>/dev/null \
      || echo "?")
    local ctx
    ctx=$(curl -s "http://127.0.0.1:$port/v1/models" 2>/dev/null \
      | python3 -c "import sys,json; r=json.load(sys.stdin); m=r['data'][0].get('meta',{}); print(m.get('n_ctx_train','?'))" 2>/dev/null \
      || echo "?")
    local pid
    pid=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
    printf "  UP  · pid=%s · model=%s · n_ctx_train=%s\n" "$pid" "$model" "$ctx"
  else
    printf "  down\n"
  fi
}

echo "Servers:"
probe 10500 "baseline (mainline f16)"
probe 10501 "turboquant (turbo3)"
probe 10502 "fallback (q8_0)"
probe 1234  "LM Studio (if running)"

echo
echo "Logs (most recent ~3 lines each):"
for f in "$REPO/logs"/*.log; do
  [[ -f "$f" ]] || continue
  echo "── $(basename "$f") ──"
  tail -3 "$f" | sed 's/^/  /'
done

echo
echo "Disk:"
du -sh "$REPO/vendor"/*/build 2>/dev/null | sed 's/^/  /'
echo "Models (symlinks):"
ls -lh "$REPO/models/" 2>/dev/null | tail -n +2 | awk '{print "  " $9 " → " $11}'
