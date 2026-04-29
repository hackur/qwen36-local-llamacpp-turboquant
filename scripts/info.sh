#!/usr/bin/env bash
# One-shot info dashboard — everything worth knowing about the running stack.
# Usage:  ./scripts/info.sh           one-shot
#         ./scripts/info.sh --watch   refresh every 2 s (Ctrl-C to exit)
#         WATCH_INTERVAL=5 ./scripts/info.sh --watch
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── tput-safe color helpers ──────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_R=$'\e[0m'
  C_GRN=$'\e[32m'; C_RED=$'\e[31m'; C_YEL=$'\e[33m'; C_CYA=$'\e[36m'; C_MAG=$'\e[35m'
else
  C_BOLD=""; C_DIM=""; C_R=""; C_GRN=""; C_RED=""; C_YEL=""; C_CYA=""; C_MAG=""
fi

hr()  { printf "${C_DIM}─%.0s${C_R}" {1..72}; echo; }
hdr() { printf "\n${C_BOLD}${C_CYA}%s${C_R}\n" "$1"; hr; }
kv()  { printf "  %-18s ${C_BOLD}%s${C_R}\n" "$1" "$2"; }
kvm() { printf "  %-18s %s\n" "$1" "$2"; }   # muted

bytes_pretty() {
  local b="$1"
  if [[ -z "$b" || "$b" == "0" || "$b" == "?" ]]; then echo "?"; return; fi
  python3 -c "
b=$b
for u in ('B','KiB','MiB','GiB','TiB'):
  if b<1024: print(f'{b:.1f} {u}'); break
  b/=1024
"
}

py_get() {
  # py_get <url> <python expr against parsed JSON `r`>
  local url="$1" expr="$2"
  curl -sf --max-time 1 "$url" 2>/dev/null | python3 -c "
import sys,json
try:
  r=json.loads(sys.stdin.read(), strict=False)
  print($expr)
except Exception:
  print('?')" 2>/dev/null || echo "?"
}

# ── ENVIRONMENT ─────────────────────────────────────────────────────────────
draw() {
  clear 2>/dev/null || printf '\ec'
  printf "${C_BOLD}${C_MAG}Qwen Local Stack — Info${C_R}     ${C_DIM}%s${C_R}\n" "$(date '+%Y-%m-%d %H:%M:%S')"

  hdr "ENVIRONMENT"
  kv "repo"      "$REPO"
  kv "branch"    "$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  kv "HEAD"      "$(git -C "$REPO" log -1 --format='%h %s' 2>/dev/null | cut -c1-60 || echo '?')"
  kv "host"      "$(scutil --get ComputerName 2>/dev/null) — $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
  kv "macOS"     "$(sw_vers -productVersion 2>/dev/null) (build $(sw_vers -buildVersion 2>/dev/null))"
  kv "uptime"    "$(uptime | sed -E 's/^.*up *([^,]+),.*/\1/')"
  local main_sha turbo_sha
  main_sha=$(git -C "$REPO/vendor/llama.cpp-mainline" rev-parse --short HEAD 2>/dev/null || echo '?')
  turbo_sha=$(git -C "$REPO/vendor/llama-cpp-turboquant" rev-parse --short HEAD 2>/dev/null || echo '?')
  kv "mainline"  "$main_sha"
  kv "turboquant" "$turbo_sha (feature/turboquant-kv-cache)"

  # ── SERVERS ────────────────────────────────────────────────────────────
  hdr "SERVERS"
  for entry in "10500:baseline (mainline f16)" "10501:turboquant (turbo3)" "10502:fallback (q8_0)" "10503:vision" "1234:LM Studio"; do
    local port="${entry%%:*}" label="${entry#*:}"
    if curl -sf --max-time 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      local pid; pid=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
      printf "  ${C_GRN}●${C_R} %-30s ${C_BOLD}:%-5s${C_R} pid=%s\n" "$label" "$port" "$pid"
    else
      printf "  ${C_DIM}○ %-30s :%-5s down${C_R}\n" "$label" "$port"
    fi
  done

  # ── ACTIVE SERVER (turboquant primary) ─────────────────────────────────
  local active_port=10501
  if curl -sf --max-time 1 "http://127.0.0.1:$active_port/health" >/dev/null 2>&1; then
    hdr "ACTIVE SERVER (:$active_port)"

    local model_alias n_ctx_train n_params model_size build n_ctx_loaded total_slots model_path is_sleeping
    model_alias=$(py_get "http://127.0.0.1:$active_port/v1/models" "r['data'][0]['id']")
    n_ctx_train=$(py_get "http://127.0.0.1:$active_port/v1/models" "r['data'][0]['meta']['n_ctx_train']")
    n_params=$(py_get "http://127.0.0.1:$active_port/v1/models" "r['data'][0]['meta']['n_params']")
    model_size=$(py_get "http://127.0.0.1:$active_port/v1/models" "r['data'][0]['meta']['size']")
    build=$(py_get "http://127.0.0.1:$active_port/props" "r['build_info']")
    n_ctx_loaded=$(py_get "http://127.0.0.1:$active_port/props" "r['default_generation_settings']['n_ctx']")
    total_slots=$(py_get "http://127.0.0.1:$active_port/props" "r['total_slots']")
    model_path=$(py_get "http://127.0.0.1:$active_port/props" "r['model_path']")
    is_sleeping=$(py_get "http://127.0.0.1:$active_port/props" "r['is_sleeping']")

    kv "model alias"  "$model_alias"
    kv "model path"   "$(echo "$model_path" | sed "s|$HOME|~|")"
    kv "params"       "$(python3 -c "n=$n_params; print(f'{n/1e9:.2f} B' if n!='?' else '?')" 2>/dev/null || echo '?')"
    kv "size on disk" "$(bytes_pretty "$model_size")"
    kv "context"      "loaded=$n_ctx_loaded · trained=$n_ctx_train"
    kv "slots"        "$total_slots"
    kv "build"        "$build"
    kv "sleeping"     "$is_sleeping"

    # Sampling defaults
    local temp top_p top_k
    temp=$(py_get  "http://127.0.0.1:$active_port/props" "round(r['default_generation_settings']['params']['temperature'],3)")
    top_p=$(py_get "http://127.0.0.1:$active_port/props" "round(r['default_generation_settings']['params']['top_p'],3)")
    top_k=$(py_get "http://127.0.0.1:$active_port/props" "r['default_generation_settings']['params']['top_k']")
    kv "sampling"     "temp=$temp top_p=$top_p top_k=$top_k"

    # ── live slots ───────────────────────────────────────────────────────
    local processing predicted prompt_n
    processing=$(py_get "http://127.0.0.1:$active_port/slots" "r[0]['is_processing']")
    if [[ "$processing" == "True" ]]; then
      kv "activity"   "${C_YEL}generating${C_R}"
    else
      kv "activity"   "idle"
    fi
  else
    hdr "ACTIVE SERVER"
    printf "  ${C_RED}● no server up on :10501 — try 'make start'${C_R}\n"
  fi

  # ── PROCESS / MEMORY ───────────────────────────────────────────────────
  hdr "PROCESS & MEMORY"
  local pid
  pid=$(pgrep -f "vendor/llama-cpp-turboquant.*llama-server" 2>/dev/null | head -1)
  if [[ -n "$pid" ]]; then
    # ps fields: rss in KB on macOS
    local etime rss_kb cpu
    read -r etime rss_kb cpu < <(ps -o etime=,rss=,%cpu= -p "$pid" 2>/dev/null | head -1)
    kv "pid"        "$pid"
    kv "uptime"     "$(echo "$etime" | xargs)"
    kv "RSS"        "$(bytes_pretty "$((rss_kb * 1024))")"
    kv "%cpu"       "${cpu:-?}"
  else
    kvm "pid" "(no llama-server running)"
  fi

  # System memory via vm_stat
  local pgsz pages_free pages_active pages_inactive pages_wired pages_compressed
  pgsz=$(sysctl -n hw.pagesize)
  vm=$(vm_stat 2>/dev/null)
  pages_free=$(echo "$vm"     | awk '/Pages free/                  {gsub(/\./,"",$3); print $3}')
  pages_active=$(echo "$vm"   | awk '/Pages active/                {gsub(/\./,"",$3); print $3}')
  pages_inactive=$(echo "$vm" | awk '/Pages inactive/              {gsub(/\./,"",$3); print $3}')
  pages_wired=$(echo "$vm"    | awk '/Pages wired down/            {gsub(/\./,"",$4); print $4}')
  pages_compressed=$(echo "$vm" | awk '/Pages occupied by compressor/ {gsub(/\./,"",$5); print $5}')
  total_mem_b=$(sysctl -n hw.memsize)
  free_b=$(( pages_free * pgsz + pages_inactive * pgsz / 2 ))   # rough "available"
  used_b=$(( total_mem_b - free_b ))
  kv "system used"  "$(bytes_pretty "$used_b") / $(bytes_pretty "$total_mem_b")"
  kv "wired"        "$(bytes_pretty "$((pages_wired * pgsz))")"
  kv "compressed"   "$(bytes_pretty "$((pages_compressed * pgsz))")"

  # ── NETWORK (offline confirmation) ─────────────────────────────────────
  hdr "NETWORK"
  if [[ -n "$pid" ]]; then
    local sockets inbound outbound
    sockets=$(lsof -nP -p "$pid" 2>/dev/null | awk '$5=="IPv4"||$5=="IPv6"')
    inbound=$(echo "$sockets" | grep "(LISTEN)"  | awk '{print $(NF-1)}' || true)
    outbound=$(echo "$sockets" | grep "(ESTABLISHED)" | awk '{print $(NF-1)}' | grep -v "^127\.0\.0\.1\|^\[::1\]" || true)
    if [[ -n "$inbound" ]]; then
      echo "$inbound" | while IFS= read -r addr; do printf "  ${C_GRN}inbound  ${C_R}        %s (LISTEN)\n" "$addr"; done
    fi
    if [[ -z "$outbound" ]]; then
      printf "  outbound           ${C_GRN}none ✓${C_R}\n"
    else
      echo "$outbound" | while IFS= read -r addr; do printf "  ${C_RED}outbound ${C_R}        %s\n" "$addr"; done
    fi
  else
    kvm "" "(no server)"
  fi

  # ── DISK ───────────────────────────────────────────────────────────────
  hdr "DISK"
  local model_disk vendor_disk logs_disk bench_disk
  model_disk=$(du -shL "$REPO/models" 2>/dev/null | cut -f1)
  vendor_disk=$(du -sh  "$REPO/vendor" 2>/dev/null | cut -f1)
  logs_disk=$(du -sh    "$REPO/logs"   2>/dev/null | cut -f1)
  bench_disk=$(du -sh   "$REPO/benchmarks" 2>/dev/null | cut -f1)
  kv "models (deref)" "$model_disk"
  kv "vendor build"   "$vendor_disk"
  kv "logs"           "$logs_disk"
  kv "benchmarks"     "$bench_disk"

  # ── LAUNCHD ────────────────────────────────────────────────────────────
  hdr "LAUNCHD"
  local ld; ld=$(launchctl list 2>/dev/null | grep "com.local.qwen3-6.turboquant" || true)
  if [[ -n "$ld" ]]; then
    local ld_pid ld_status ld_label
    read -r ld_pid ld_status ld_label <<< "$ld"
    if [[ "$ld_pid" == "-" ]]; then
      kv "$ld_label" "${C_YEL}loaded but not running (status=$ld_status)${C_R}"
    else
      kv "$ld_label" "${C_GRN}running pid=$ld_pid${C_R}"
    fi
  else
    kvm "agent" "not installed (run 'make install-launchd' to enable auto-start)"
  fi

  # ── LAST BENCH ─────────────────────────────────────────────────────────
  hdr "LAST BENCHMARKS"
  if [[ -d "$REPO/benchmarks" ]]; then
    local results
    # Find bench logs (uncompressed first, then gzipped)
    results=$(ls -t "$REPO/logs"/bench-*.log "$REPO/logs"/bench-*.log.gz 2>/dev/null | head -3)
    if [[ -n "$results" ]]; then
      local cat_cmd
      while IFS= read -r f; do
        local name; name=$(basename "$f" .log); name=${name%.log.gz}
        cat_cmd="cat"; [[ "$f" == *.gz ]] && cat_cmd="gzcat"
        local avg_g avg_p
        avg_g=$($cat_cmd "$f" 2>/dev/null | grep "avg gen:" | tail -1 | sed -E 's/.*avg gen: ([0-9.]+).*/\1/' || echo '?')
        avg_p=$($cat_cmd "$f" 2>/dev/null | grep "avg prompt:" | tail -1 | sed -E 's/.*avg prompt: ([0-9.]+).*/\1/' || echo '?')
        [[ -n "$avg_g" ]] || avg_g='?'
        [[ -n "$avg_p" ]] || avg_p='?'
        kv "$name" "${avg_g} gen / ${avg_p} prompt tok/s"
      done <<< "$results"
    else
      kvm "" "(no bench logs yet — run 'make bench')"
    fi
    # Last needle (uncompressed or gz)
    local needle_log
    needle_log=$(ls -t "$REPO/logs"/needle-*.log "$REPO/logs"/needle-*.log.gz 2>/dev/null | head -1)
    if [[ -n "$needle_log" ]]; then
      cat_cmd="cat"; [[ "$needle_log" == *.gz ]] && cat_cmd="gzcat"
      $cat_cmd "$needle_log" 2>/dev/null | grep -E "✓|✗|prompt_n" | tail -2 | sed 's/^/  /'
    fi
  fi

  echo
}

# ── main ────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--watch" ]]; then
  IV="${WATCH_INTERVAL:-2}"
  trap 'echo; echo "(stopped)"; exit 0' INT
  while true; do
    draw
    printf "${C_DIM}refreshing every %ss · Ctrl-C to exit${C_R}\n" "$IV"
    sleep "$IV"
  done
else
  draw
fi
