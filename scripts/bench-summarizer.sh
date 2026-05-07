#!/usr/bin/env bash
# bench-summarizer.sh — benchmark candidate summarizer models for the
# tier-1 compaction summarizer slot (see docs/compaction-strategy.md §11).
#
# This script is BENCH-PREP. It produces a side-by-side comparison table
# plus the actual summary text from each (model, fixture) cell so a human
# can eyeball quality before picking a winner. The script does NOT make
# the decision.
#
# Candidates (alias names from `make models` / scripts/list-models.sh):
#   gemma4-e4b   — dense ~4B; q-quality bias.
#   nemotron-4b  — dense ~4B; different training mix.
#   tiny         — much smaller; speed/cost floor.
#
# Workload: 5 inline synthetic conversation transcripts, ~5K tokens each,
# representing the kinds of contexts the proxy's tier-1 summarizer will
# see in practice (tool output, chit-chat, mixed code+prose).
#
# Per (model, fixture) cell the script:
#   1. starts the model on a transient port (10520 + offset)
#   2. waits for /health
#   3. issues a single summarization request, captures llama.cpp timings
#   4. records load time, prefill tok/s, gen tok/s, wall clock, summary
#   5. tears the server down before moving on (one model at a time, so
#      memory budget is never exceeded)
#
# Output: benchmarks/summarizer-bench-<ts>.md with rubric, comparison
# table, and full summaries for human grading.
#
# Run fully offline. No new deps beyond what the rest of the repo uses
# (curl, jq, python3).

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
OUT="$REPO/benchmarks/summarizer-bench-$TS.md"
LOGDIR="$REPO/logs/summarizer-bench-$TS"
mkdir -p "$REPO/benchmarks" "$LOGDIR"

# Candidate models — must match alias names available under models/.
CANDIDATES=(gemma4-e4b nemotron-4b tiny)

# Transient port range — picked above the standard 10500-10503 servers
# and the A/B harness usual range, so a normal dev session can keep its
# primary running on 10501 while this bench runs.
BASE_PORT=10520

# Single shared summarization instruction. Kept identical across models
# so the comparison is apples-to-apples.
SUMMARIZE_INSTRUCTION='You are a compaction summarizer. Produce a faithful, structured summary of the conversation above. Preserve every named entity, decision, file path, command, and unresolved question. Aim for ~400 tokens. Do not invent facts. Output plain prose followed by a short bulleted list of unresolved questions.'

# ─────────────────────────────────────────────────────────────────────
# Fixtures — 5 synthesized transcripts. Each is built by repeating a
# small core to land near ~5K tokens (~20K chars) without dragging in
# external test data. Fixtures live as variables here, not files.
# ─────────────────────────────────────────────────────────────────────

# Helper: repeat a string N times and emit it.
_repeat() {
  local s="$1" n="$2" i=0
  while (( i < n )); do printf '%s' "$s"; i=$((i+1)); done
}

build_fixture_1() {
  # Tool-output heavy: simulated grep/find/git logs interleaved with
  # short user/assistant turns. This is the "agent loop" shape.
  {
    echo "USER: I need to find every place we read the OPENAI_API_KEY env var in the proxy."
    echo "ASSISTANT: I'll grep the proxy/ tree for that."
    echo "TOOL_RESULT (grep -rn OPENAI_API_KEY proxy/):"
    _repeat "proxy/handlers/chat.py:42:    key = os.environ.get('OPENAI_API_KEY')\nproxy/handlers/embed.py:18:    key = os.environ['OPENAI_API_KEY']\nproxy/middleware/auth.py:77:    if not os.environ.get('OPENAI_API_KEY'):\nproxy/eval/replay.py:113:    headers['Authorization'] = f'Bearer {os.environ[\"OPENAI_API_KEY\"]}'\n" 30
    echo
    echo "USER: Decision: we should centralize this in proxy/config.py::Settings.openai_api_key."
    echo "ASSISTANT: Agreed. Filing as task #88. Unresolved: do we want to support per-request override via a header?"
    echo "TOOL_RESULT (git log --oneline -n 50 -- proxy/handlers/):"
    _repeat "abc1234 fix(proxy): brace-balance sniffUsage so completion_tokens is logged\ndef5678 feat(proxy): add tier-0 elision for large tool_result blocks\n" 20
  }
}

build_fixture_2() {
  # Chit-chat heavy: long-running planning conversation, low information
  # density, lots of pronouns and back-references. Tests coherence.
  {
    echo "USER: So I've been thinking about the watermark. 70% felt arbitrary."
    echo "ASSISTANT: It is. The doc literally says it's a guess. We should probably set it once we have a week of Phase 0 data."
    echo "USER: Right. And then there's the whole question of CPU vs GPU for the summarizer."
    echo "ASSISTANT: Yeah. If we run gemma4-e4b on CPU we free the GPU for the primary, but inference will be slower."
    _repeat "USER: How slow are we talking?\nASSISTANT: 10-20 tok/s on CPU for a 4B dense model is realistic on this M-series box. Fine for background work.\nUSER: Background being defined as 'user is not waiting on it', right?\nASSISTANT: Yes. The compaction is fire-and-forget once the marker is injected.\nUSER: OK. And nemotron is also 4B dense?\nASSISTANT: Roughly, yes. Different training mix though — Nemotron is more instruction-following heavy.\nUSER: And tiny?\nASSISTANT: Tiny is much smaller. Free in compute terms. Quality is the question.\n" 25
    echo "USER: Final decision deferred until the bench runs. That's task #42."
  }
}

build_fixture_3() {
  # Code-heavy: source dump + diff review. Tests entity preservation
  # (function names, file paths, line numbers).
  {
    echo "USER: Review this patch."
    echo "ASSISTANT: Reading."
    echo "PATCH:"
    _repeat "--- a/proxy/middleware/elision.py\n+++ b/proxy/middleware/elision.py\n@@ -42,7 +42,11 @@ def elide_tool_results(messages, watermark=0.7):\n-    if total_tokens(messages) < watermark * MAX_CTX:\n+    used = total_tokens(messages)\n+    if used < watermark * MAX_CTX:\n         return messages\n+    log.info('elision triggered: %d/%d (%.2f%%)', used, MAX_CTX, 100*used/MAX_CTX)\n     return _stub_large_blocks(messages, threshold=THRESHOLD_BYTES)\n" 25
    echo "USER: LGTM. One nit: log at debug, not info — this fires every request once we cross the watermark."
    echo "ASSISTANT: Good catch. Filed as #91."
    echo "TOOL_RESULT (pytest -k elision):"
    _repeat "tests/test_elision.py::test_under_watermark_passthrough PASSED\ntests/test_elision.py::test_over_watermark_stubs_large PASSED\ntests/test_elision.py::test_idempotent_under_repeat PASSED\n" 25
  }
}

build_fixture_4() {
  # Decision-tracking heavy: a planning session with multiple resolved
  # and unresolved decisions. Tests the rubric's 'decision preservation'
  # axis directly.
  {
    echo "USER: Let's lock down the open questions in compaction-strategy §11."
    echo "ASSISTANT: There are five. Watermark, summarizer choice, CPU/GPU placement, proxy topology, persistence format."
    _repeat "USER: Watermark — defer until Phase 0 data. AGREED.\nASSISTANT: Logged as deferred.\nUSER: Summarizer — bench all three. AGREED, that's task #42.\nASSISTANT: Logged.\nUSER: CPU vs GPU — let's bench summarizer on CPU as part of #42. AGREED.\nASSISTANT: Logged. Unresolved sub-question: do we measure power draw too?\nUSER: Topology — single proxy on :11500, picks upstream by model field. AGREED.\nASSISTANT: Logged as decision D-17.\nUSER: Persistence — JSON in ~/.cache/qwen-compact/. AGREED. No SQLite.\nASSISTANT: Logged as D-18.\n" 18
    echo "USER: Unresolved: power draw measurement, and whether the marker contract for caveman-self-compact lives in the proxy or in the model's system prompt."
  }
}

build_fixture_5() {
  # Mixed-language / structured-data heavy: JSON blobs, error tracebacks,
  # config files. Tests whether tiny smears structured content.
  {
    echo "USER: The proxy is OOMing on long sessions. Here's the traceback."
    echo "TRACEBACK:"
    _repeat "Traceback (most recent call last):\n  File \"proxy/server.py\", line 312, in handle_chat\n    resp = await upstream.complete(messages, **opts)\n  File \"proxy/upstream/llama.py\", line 89, in complete\n    async with self._session.post(url, json=payload) as r:\n  File \"aiohttp/client.py\", line 1141, in __aenter__\n    self._resp = await self._coro\nMemoryError\n" 20
    echo "USER: And here's the config we're running."
    echo "CONFIG:"
    _repeat '{"mode": "enforce", "tiers": {"tier0": true, "tier1": true}, "watermark": 0.7, "summarizer": {"model": "TBD", "max_tokens": 600, "temperature": 0.2}, "elision": {"threshold_bytes": 8192, "stub_format": "ascii-art-marker"}}' 30
    echo
    echo "ASSISTANT: The OOM is in aiohttp on the request build, which means the prompt itself is too big — tier-0 isn't catching it before we hit upstream. Decision: lower elision.threshold_bytes to 4096 and re-test. Unresolved: do we also need a hard cap on total prompt bytes as a safety net?"
  }
}

# ─────────────────────────────────────────────────────────────────────
# Server lifecycle
# ─────────────────────────────────────────────────────────────────────

start_model() {
  local alias="$1" port="$2"
  local logfile="$LOGDIR/$alias-$port.log"
  # Use the standard turboquant launcher; it sources model-defaults.env
  # and handles KV / RoPE per alias. Background it; capture log.
  PORT="$port" MODEL="$alias" \
    "$REPO/scripts/start-turboquant.sh" >"$logfile" 2>&1 &
  echo $!
}

wait_health() {
  local port="$1" timeout="${2:-180}" t0
  t0=$(date +%s)
  while true; do
    if curl -sf --max-time 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      return 0
    fi
    if (( $(date +%s) - t0 > timeout )); then
      echo "  ❌ /health did not come up within ${timeout}s on :$port" >&2
      return 1
    fi
    sleep 1
  done
}

stop_pid() {
  local pid="$1"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    # give it 5s to exit cleanly, then SIGKILL.
    local i=0
    while kill -0 "$pid" 2>/dev/null && (( i < 50 )); do
      sleep 0.1; i=$((i+1))
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
}

# ─────────────────────────────────────────────────────────────────────
# Single bench cell
# ─────────────────────────────────────────────────────────────────────
#
# Issues one chat completion against :$port with the fixture text as the
# user message and SUMMARIZE_INSTRUCTION as the trailing instruction.
# Returns a JSON object on stdout with: load_s, prefill_tps, gen_tps,
# wall_s, prompt_n, completion_n, summary.
bench_cell() {
  local port="$1" fixture_text="$2" load_s="$3"
  local payload
  # Build the payload via python3 for safe JSON escaping (no jq dep on
  # the input side — the rest of the repo already uses python3 for this).
  payload=$(FIXTURE="$fixture_text" INSTR="$SUMMARIZE_INSTRUCTION" python3 -c '
import json, os
msgs = [
  {"role": "user",
   "content": os.environ["FIXTURE"] + "\n\n---\n\n" + os.environ["INSTR"]},
]
print(json.dumps({
  "model": "local",
  "messages": msgs,
  "max_tokens": 800,
  "temperature": 0.2,
  "chat_template_kwargs": {"enable_thinking": False},
}))
')
  local t0 t1 wall_s resp
  t0=$(python3 -c 'import time; print(time.time())')
  resp=$(curl -sf "http://127.0.0.1:$port/v1/chat/completions" \
            -H "Content-Type: application/json" \
            --data-binary "$payload") || resp='{"error":"request failed"}'
  t1=$(python3 -c 'import time; print(time.time())')
  wall_s=$(python3 -c "print(f'{$t1 - $t0:.2f}')")

  # Pull timings + content via jq. llama-server returns timings under
  # .timings; the OpenAI-compat shape puts content under .choices[0].
  python3 - "$resp" "$load_s" "$wall_s" <<'PY'
import json, sys
resp_raw, load_s, wall_s = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.loads(resp_raw)
except Exception:
    d = {}
t = d.get("timings") or {}
choices = d.get("choices") or []
content = ""
if choices:
    content = (choices[0].get("message") or {}).get("content") or ""
out = {
    "load_s":        float(load_s),
    "wall_s":        float(wall_s),
    "prefill_tps":   t.get("prompt_per_second", 0) or 0,
    "gen_tps":       t.get("predicted_per_second", 0) or 0,
    "prompt_n":      t.get("prompt_n", 0) or 0,
    "completion_n":  t.get("predicted_n", 0) or 0,
    "summary":       content,
    "error":         d.get("error", ""),
}
print(json.dumps(out))
PY
}

# ─────────────────────────────────────────────────────────────────────
# Main matrix
# ─────────────────────────────────────────────────────────────────────

# Prepare fixture texts in an array (bash assoc-array of strings).
declare -a FIX_NAMES=(tool-heavy chit-chat code-heavy decision-heavy structured)
declare -a FIX_TEXTS
FIX_TEXTS+=("$(build_fixture_1)")
FIX_TEXTS+=("$(build_fixture_2)")
FIX_TEXTS+=("$(build_fixture_3)")
FIX_TEXTS+=("$(build_fixture_4)")
FIX_TEXTS+=("$(build_fixture_5)")

# Results JSONL — one line per cell, easier to post-process than tab-arrays.
RESULTS_JSONL="$LOGDIR/results.jsonl"
: > "$RESULTS_JSONL"

offset=0
for alias in "${CANDIDATES[@]}"; do
  port=$(( BASE_PORT + offset ))
  offset=$(( offset + 1 ))

  echo "── [$alias] starting on :$port ──"
  t_start=$(python3 -c 'import time; print(time.time())')
  pid=$(start_model "$alias" "$port")
  if ! wait_health "$port" 240; then
    echo "  ❌ skipping $alias (failed to start)"
    stop_pid "$pid"
    continue
  fi
  t_ready=$(python3 -c 'import time; print(time.time())')
  load_s=$(python3 -c "print(f'{$t_ready - $t_start:.2f}')")
  echo "  ready in ${load_s}s (pid=$pid)"

  for i in "${!FIX_NAMES[@]}"; do
    fname="${FIX_NAMES[$i]}"
    ftext="${FIX_TEXTS[$i]}"
    echo "  → fixture $fname …"
    cell=$(bench_cell "$port" "$ftext" "$load_s")
    # Stamp each row with model + fixture metadata.
    python3 -c "
import json, sys
row = json.loads(sys.argv[1])
row['model']   = '$alias'
row['fixture'] = '$fname'
print(json.dumps(row))
" "$cell" >> "$RESULTS_JSONL"
  done

  echo "  stopping $alias …"
  stop_pid "$pid"
  # Brief settle so the next start sees the port free.
  sleep 2
done

# ─────────────────────────────────────────────────────────────────────
# Render report
# ─────────────────────────────────────────────────────────────────────

OUT="$OUT" RESULTS_JSONL="$RESULTS_JSONL" TS="$TS" python3 <<'PY'
import json, os, pathlib

out_path = pathlib.Path(os.environ["OUT"])
results  = pathlib.Path(os.environ["RESULTS_JSONL"])
ts       = os.environ["TS"]

rows = [json.loads(l) for l in results.read_text().splitlines() if l.strip()]

models   = sorted({r["model"] for r in rows})
fixtures = sorted({r["fixture"] for r in rows})

def cell(model, fixture):
    for r in rows:
        if r["model"] == model and r["fixture"] == fixture:
            return r
    return None

def fmt(x, n=1):
    try: return f"{float(x):.{n}f}"
    except Exception: return "—"

lines = []
lines.append(f"# Summarizer bench — {ts}\n")
lines.append("Bench-prep for docs/compaction-strategy.md §11 summarizer-model choice.")
lines.append("This report is an INPUT to a human decision; it does not pick a winner.\n")

lines.append("## Evaluation rubric\n")
lines.append("**Speed axes** (from the table below):")
lines.append("- `wall_s` — total user-perceived latency per summary (lower is better).")
lines.append("- `gen_tps` — generation throughput; matters once watermark fires often.")
lines.append("- `prefill_tps` — prompt ingest rate; dominates wall-clock at 5K-token inputs.")
lines.append("- `load_s` — cold-start cost; only paid once per session if the summarizer\n  is kept warm, but matters if we spin it on demand.\n")

lines.append("**Quality axes** (eyeball the side-by-side summaries below):")
lines.append("- *Entity preservation* — file paths, function names, task IDs, decisions D-NN,\n  config keys. Compare against the fixture text. Missing entities = bad.")
lines.append("- *Coherence* — does the summary read as a single coherent note, or does it\n  ramble / repeat / contradict itself?")
lines.append("- *Length compliance* — instruction asks for ~400 tokens. Models that ignore\n  this and produce 50-token stubs (or 2000-token essays) cost us either fidelity\n  or context budget.")
lines.append("- *Unresolved-question capture* — the trailing bullet list. Each fixture has\n  explicit unresolved items; check they all show up.\n")

lines.append("**Existing tradeoffs** (from compaction-strategy.md §11):")
lines.append("- `gemma4-e4b` — dense ~4B; the doc's prior on \"better summaries, ~8 GB\".")
lines.append("- `nemotron-4b` — dense ~4B with a different training mix; doc's prior on\n  \"faster, ~2.8 GB\". Verify both claims here.")
lines.append("- `tiny` — much smaller; free in compute, low-quality prior. Floor candidate.\n")

lines.append("## Speed table\n")
lines.append("| model | fixture | load_s | prefill_tps | gen_tps | wall_s | prompt_n | completion_n |")
lines.append("|---|---|---:|---:|---:|---:|---:|---:|")
for m in models:
    for f in fixtures:
        r = cell(m, f)
        if not r:
            lines.append(f"| {m} | {f} | — | — | — | — | — | — |")
            continue
        lines.append(
            f"| {m} | {f} | {fmt(r['load_s'])} | {fmt(r['prefill_tps'])} "
            f"| {fmt(r['gen_tps'])} | {fmt(r['wall_s'])} "
            f"| {r['prompt_n']} | {r['completion_n']} |"
        )
lines.append("")

lines.append("## Aggregates\n")
lines.append("| model | mean wall_s | mean gen_tps | mean completion_n |")
lines.append("|---|---:|---:|---:|")
for m in models:
    cells = [r for r in rows if r["model"] == m]
    if not cells:
        lines.append(f"| {m} | — | — | — |"); continue
    mw = sum(float(r["wall_s"]) for r in cells) / len(cells)
    mt = sum(float(r["gen_tps"]) for r in cells) / len(cells)
    mc = sum(float(r["completion_n"]) for r in cells) / len(cells)
    lines.append(f"| {m} | {mw:.2f} | {mt:.1f} | {mc:.0f} |")
lines.append("")

lines.append("## Summaries side-by-side\n")
lines.append("Read these against the fixture intent (the names hint at it).\n"
             "Look for entity drops, hallucinations, and length compliance.\n")
for f in fixtures:
    lines.append(f"### Fixture: `{f}`\n")
    for m in models:
        r = cell(m, f)
        lines.append(f"#### {m}\n")
        if not r:
            lines.append("_no result_\n"); continue
        if r.get("error"):
            lines.append(f"_error_: `{r['error']}`\n")
        s = (r.get("summary") or "").strip() or "_(empty)_"
        lines.append("```")
        lines.append(s)
        lines.append("```\n")

lines.append("---")
lines.append("## Next step\n")
lines.append("Pick a winner and update:")
lines.append("- `docs/compaction-strategy.md` §11 (resolve the open question)")
lines.append("- `proxy/config.yaml` `summarizer.model` (or wherever the proxy reads it)")
lines.append("- close task #42 with a one-paragraph rationale referencing this report")

out_path.write_text("\n".join(lines) + "\n")
print(f"wrote {out_path}")
PY

echo
echo "report → $OUT"
echo "raw    → $RESULTS_JSONL"
echo "logs   → $LOGDIR"
