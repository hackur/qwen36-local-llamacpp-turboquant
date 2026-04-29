#!/usr/bin/env bash
# Print all model aliases available in models/, with size, quant, and capabilities.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -d "$REPO/models" ]]; then
  echo "no models/ — run scripts/symlink-models.sh first"
  exit 1
fi

# Find what's currently loaded by any running server (for the * marker)
loaded_paths=()
for port in 10500 10501 10502 10503; do
  if curl -sf --max-time 1 "http://127.0.0.1:$port/props" >/dev/null 2>&1; then
    p=$(curl -s "http://127.0.0.1:$port/props" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('model_path',''))" 2>/dev/null)
    [[ -n "$p" ]] && loaded_paths+=("$p")
  fi
done

bytes_pretty() {
  python3 -c "
b=$1
for u in ('B','KiB','MiB','GiB','TiB'):
  if b<1024: print(f'{b:.1f}{u}'); break
  b/=1024
"
}

bold=$'\e[1m'; dim=$'\e[2m'; cya=$'\e[36m'; grn=$'\e[32m'; r=$'\e[0m'

printf "${bold}%-13s %8s %10s %-9s %s${r}\n" "ALIAS" "SIZE" "QUANT" "VISION" "REAL PATH"
printf "${dim}%s${r}\n" "──────────────────────────────────────────────────────────────────────────────"

# Iterate over alias.gguf links (skip mmproj)
for link in "$REPO/models"/*.gguf; do
  [[ -e "$link" ]] || continue
  name=$(basename "$link" .gguf)
  [[ "$name" == *.mmproj ]] && continue
  real=$(readlink "$link")
  [[ -z "$real" ]] && real="$link"
  if [[ -f "$real" ]]; then
    size=$(wc -c < "$real" | tr -d ' ')
    size_h=$(bytes_pretty "$size")
  else
    size_h="(missing)"
  fi
  # Heuristic quant from filename
  quant=$(basename "$real" | grep -oE -i "Q[0-9]_K_M|Q[0-9]_K_S|Q[0-9]_K|Q[0-9]_[0-9]|IQ[0-9]_[A-Z]+|MXFP[0-9]|F16|BF16|F32" | head -1 || true)
  [[ -z "$quant" ]] && quant="?"
  vision="—"
  [[ -f "$REPO/models/$name.mmproj.gguf" ]] && vision="${grn}yes${r}"

  marker=" "
  for p in "${loaded_paths[@]}"; do
    [[ "$p" == "$real" ]] && marker="${cya}*${r}"
  done

  printf "%s${bold}%-13s${r} %8s %10s %-19b %s\n" "$marker" "$name" "$size_h" "$quant" "$vision" "${real/#$HOME/~}"
done

echo
echo "${dim}* = currently loaded by a running server${r}"
echo "Start with:  MODEL=<alias> ./scripts/start-turboquant.sh"
echo "Or:          MODEL=<alias> make start"
