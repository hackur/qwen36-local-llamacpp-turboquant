#!/usr/bin/env bash
# compare-lmstudio.sh — head-to-head bench vs LM Studio's local-server runtime.
#
# Runs scripts/bench.py RUNS times against our TurboQuant primary AND against
# LM Studio's OpenAI-compatible server, then writes a side-by-side report
# (per-run + mean ± stddev) so we can see how our custom runtime compares to
# the off-the-shelf llama.cpp build LM Studio ships.
#
# LM Studio's local server is interactive: you have to open the LM Studio app,
# click "Local Server" in the sidebar, load the same Qwen-family model the
# primary is serving, and hit "Start Server". This script does NOT start it
# for you and will NOT tear it down on exit — we only own our transient
# runbook ports (10595–10599). LM Studio's port (:1234 by default) is left
# alone in every code path.
#
# Usage:
#   ./scripts/compare-lmstudio.sh                        # 3 runs each, defaults
#   RUNS=5 ./scripts/compare-lmstudio.sh
#   LMSTUDIO_PORT=1234 OUR_PORT=10501 ./scripts/compare-lmstudio.sh
#
# Read-only on both servers — no model swap, no port rebind, no kill.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

case "${1:-}" in -h|--help) print_help_from_header; exit 0 ;; esac

LMSTUDIO_PORT="${LMSTUDIO_PORT:-1234}"
OUR_PORT="${OUR_PORT:-10501}"
RUNS="${RUNS:-3}"
COOLDOWN="${COOLDOWN:-60}"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO/benchmarks/lmstudio-compare-${TS}.md"

# Refuse to clobber any of the runbook transient ports — those belong to the
# other sustained-load scripts and a stray match here would mean the user
# typo'd OUR_PORT. LM Studio's :1234 is fine; we never bind it.
for p in 10595 10596 10597 10598 10599; do
  if [[ "$LMSTUDIO_PORT" == "$p" || "$OUR_PORT" == "$p" ]]; then
    echo "❌ refusing to use runbook port :$p — pick a different port" >&2
    exit 1
  fi
done

mkdir -p "$REPO/benchmarks" "$REPO/logs"

# This script does not own any server process. The trap is intentionally empty
# (well, a no-op echo) — we explicitly do NOT kill LM Studio (didn't start it)
# and do NOT kill our primary on :10501 (launchd-managed).
on_exit() { :; }
trap on_exit EXIT INT TERM

probe_models() {
  local port="$1"
  curl -sf --max-time 5 "http://127.0.0.1:${port}/v1/models" 2>/dev/null
}

# Extract a "model id" from /v1/models JSON without jq. Picks the first
# "id":"…" string. Lowercased for a contains-match downstream.
first_model_id() {
  printf "%s" "$1" \
    | tr ',' '\n' \
    | awk -F'"' '/"id"[[:space:]]*:/ {print tolower($4); exit}'
}

# stats <file> — same shape as test-battery-ac.sh: mean stddev.
stats() {
  awk '
    { if ($1 == "?" || $1 == "") { bad=1; next }
      n++; s+=$1; xs[n]=$1 }
    END {
      if (bad || n==0) { print "? ?"; exit }
      m=s/n; ss=0
      for (i=1;i<=n;i++){ d=xs[i]-m; ss+=d*d }
      sd=(n>1)?sqrt(ss/(n-1)):0
      printf "%.2f %.2f\n", m, sd
    }
  ' "$1"
}

# ── pre-flight ──────────────────────────────────────────────────────────────
OUR_RAW="$(probe_models "$OUR_PORT" || true)"
if [[ -z "$OUR_RAW" ]]; then
  echo "❌ TurboQuant server not reachable on :${OUR_PORT}/v1/models" >&2
  echo "   Start the primary (\`make start\`) or pass OUR_PORT=<other>." >&2
  exit 1
fi

LMS_RAW="$(probe_models "$LMSTUDIO_PORT" || true)"
if [[ -z "$LMS_RAW" ]]; then
  cat >&2 <<EOF
❌ LM Studio not running on :${LMSTUDIO_PORT}.

   Open the LM Studio app, click "Local Server" in the left sidebar,
   load a Qwen-family model (ideally the same one our primary is serving:
   \`$(first_model_id "$OUR_RAW")\`), and click "Start Server". Default port
   is :1234. Then re-run this script.
EOF
  exit 1
fi

OUR_ID="$(first_model_id "$OUR_RAW")"
LMS_ID="$(first_model_id "$LMS_RAW")"
: "${OUR_ID:=unknown}" "${LMS_ID:=unknown}"
echo "our model id      : $OUR_ID"
echo "LM Studio model id: $LMS_ID"

# Loose match: both should be a Qwen-family model. We don't require an exact
# id match because LM Studio names models by file path / hub slug, while our
# server reports the alias. As long as both look like Qwen-3.x we proceed.
case "$OUR_ID$LMS_ID" in
  *qwen*qwen*) ;;
  *) echo "⚠️  one or both servers don't look like Qwen models" >&2
     echo "   our='$OUR_ID' lmstudio='$LMS_ID' — comparison may not be apples-to-apples" >&2 ;;
esac

# ── per-arm runner ──────────────────────────────────────────────────────────
# run_arm <label> <port> — RUNS× bench.py against an *already-running* server.
# Captures gen and prompt tok/s into per-arm .runs / .prompts files.
run_arm() {
  local label="$1" port="$2"
  local log="$REPO/logs/lmstudio-compare-${TS}-${label}.log"
  local runs_file="$REPO/logs/lmstudio-compare-${TS}-${label}.runs"
  local prompts_file="$REPO/logs/lmstudio-compare-${TS}-${label}.prompts"
  : > "$runs_file"; : > "$prompts_file"; : > "$log"

  echo "── arm: ${label} on :${port} (${RUNS} runs) ──"
  local i out gen prompt
  for i in $(seq 1 "$RUNS"); do
    echo "  bench ${i}/${RUNS} (${label})"
    out="$(python3 "$SCRIPT_DIR/bench.py" "$port" "${label}-${i}" 2>&1 || true)"
    printf "%s\n" "$out" >> "$log"
    gen=$(printf "%s\n" "$out"    | awk '/avg gen:/ {print $3; exit}')
    prompt=$(printf "%s\n" "$out" | awk '/avg prompt:/ {print $7; exit}')
    : "${gen:=?}" "${prompt:=?}"
    echo "$gen"    >> "$runs_file"
    echo "$prompt" >> "$prompts_file"
  done
}

# ── arm 1: ours ─────────────────────────────────────────────────────────────
"$SCRIPT_DIR/diagnose-variance.sh" --tag "lmstudio-compare-${TS}-ours-pre"  >/dev/null || true
run_arm "ours" "$OUR_PORT"
"$SCRIPT_DIR/diagnose-variance.sh" --tag "lmstudio-compare-${TS}-ours-post" >/dev/null || true

if (( COOLDOWN > 0 )); then
  echo "  cool-down ${COOLDOWN}s between arms…"
  sleep "$COOLDOWN"
fi

# ── arm 2: LM Studio ────────────────────────────────────────────────────────
"$SCRIPT_DIR/diagnose-variance.sh" --tag "lmstudio-compare-${TS}-lmstudio-pre"  >/dev/null || true
run_arm "lmstudio" "$LMSTUDIO_PORT"
"$SCRIPT_DIR/diagnose-variance.sh" --tag "lmstudio-compare-${TS}-lmstudio-post" >/dev/null || true

# ── report ──────────────────────────────────────────────────────────────────
OURS_RUNS="$REPO/logs/lmstudio-compare-${TS}-ours.runs"
LMS_RUNS="$REPO/logs/lmstudio-compare-${TS}-lmstudio.runs"
OURS_PROMPTS="$REPO/logs/lmstudio-compare-${TS}-ours.prompts"
LMS_PROMPTS="$REPO/logs/lmstudio-compare-${TS}-lmstudio.prompts"

read -r OURS_MEAN OURS_SD < <(stats "$OURS_RUNS")
read -r LMS_MEAN  LMS_SD  < <(stats "$LMS_RUNS")
read -r OURS_PMEAN OURS_PSD < <(stats "$OURS_PROMPTS")
read -r LMS_PMEAN  LMS_PSD  < <(stats "$LMS_PROMPTS")

# Delta = (ours - lmstudio) / lmstudio × 100. Positive → we're faster.
DELTA=$(awk -v a="$OURS_MEAN" -v b="$LMS_MEAN" 'BEGIN{
  if (a+0>0 && b+0>0) printf "%.1f", (a-b)/b*100; else print "?"
}')

{
  echo "# TurboQuant vs LM Studio — gen/prompt tok/s comparison"
  echo
  echo "Run: ${TS}  ours: :${OUR_PORT} (\`${OUR_ID}\`)  LM Studio: :${LMSTUDIO_PORT} (\`${LMS_ID}\`)  RUNS/arm: ${RUNS}"
  echo
  echo "## Per-run gen tok/s"
  echo
  printf "| arm |"
  for i in $(seq 1 "$RUNS"); do printf " %d |" "$i"; done
  echo " mean ± stddev |"
  printf "|---|"
  for i in $(seq 1 "$RUNS"); do printf "---:|"; done
  echo "---:|"
  printf "| ours |"
  while read -r v; do printf " %s |" "$v"; done < "$OURS_RUNS"
  printf " %s ± %s |\n" "$OURS_MEAN" "$OURS_SD"
  printf "| lmstudio |"
  while read -r v; do printf " %s |" "$v"; done < "$LMS_RUNS"
  printf " %s ± %s |\n" "$LMS_MEAN" "$LMS_SD"
  echo
  echo "## Per-run prompt tok/s"
  echo
  printf "| arm |"
  for i in $(seq 1 "$RUNS"); do printf " %d |" "$i"; done
  echo " mean ± stddev |"
  printf "|---|"
  for i in $(seq 1 "$RUNS"); do printf "---:|"; done
  echo "---:|"
  printf "| ours |"
  while read -r v; do printf " %s |" "$v"; done < "$OURS_PROMPTS"
  printf " %s ± %s |\n" "$OURS_PMEAN" "$OURS_PSD"
  printf "| lmstudio |"
  while read -r v; do printf " %s |" "$v"; done < "$LMS_PROMPTS"
  printf " %s ± %s |\n" "$LMS_PMEAN" "$LMS_PSD"
  echo
  echo "## Conclusion"
  echo
  if [[ "$DELTA" == "?" ]]; then
    echo "Delta could not be computed (one arm reported '?'). Inspect the"
    echo "per-arm bench logs in \`logs/lmstudio-compare-${TS}-*.log\` for failures."
  else
    sign_word="faster"
    case "$DELTA" in -*) sign_word="slower" ;; esac
    abs_delta="${DELTA#-}"
    echo "On gen tok/s, our TurboQuant runtime is **${abs_delta}% ${sign_word}**"
    echo "than LM Studio on this hardware (ours mean ${OURS_MEAN} vs LM Studio"
    echo "mean ${LMS_MEAN}). If the stddev bands above overlap the delta, the"
    echo "result is within noise — re-run with RUNS=5+ before drawing a"
    echo "conclusion. Note that LM Studio's runtime, KV cache type, and"
    echo "context length may differ from ours; verify in the LM Studio UI."
  fi
  echo
  echo "Raw bench output: \`logs/lmstudio-compare-${TS}-*.log\`."
  echo "Variance snapshots: \`logs/variance-*-lmstudio-compare-${TS}-*\`."
} > "$OUT"

echo
echo "wrote $OUT"
