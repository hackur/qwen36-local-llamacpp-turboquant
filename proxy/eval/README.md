# proxy/eval — quality-evaluation harness

Implements items 1 (replay harness) and 2 (needle test) from
`docs/compaction-strategy.md` §8 (Quality safeguards). The decision-
preservation eval (§8.3) lives as a placeholder under `fixtures/` because it
requires hand-labeled real sessions.

The harness is **independent of the proxy implementation**. It speaks plain
HTTP to any endpoint that implements OpenAI Chat Completions plus the
debug-rewrite contract documented below. The proxy doesn't have to exist yet.

Stack: Python 3.11+, stdlib + urllib only. No third-party deps.

---

## The rewritten-request contract (proxy team: please honor this)

The proxy is normally invisible; replay needs a way to peek at what it
would have forwarded. We use a debug header on the request and three
response headers carrying the rewrite metadata.

### Request

The replay client sets:

| Header                  | Value | Meaning                                                |
|-------------------------|-------|--------------------------------------------------------|
| `x-debug-rewritten`     | `1`   | "Tell me what you rewrote." Proxy SHOULD then populate the response headers below. |

The proxy MAY also honor `x-compact: off` (per §8.5) which suppresses
compaction entirely. Replay does NOT set this; we want to observe rewrites.

When `x-debug-rewritten: 1` is set, the proxy MAY skip the upstream call
entirely and return an empty 200 with just the rewrite headers — replay
does not consume the model output. This is the recommended cheap path.

### Response

The proxy SHOULD set the following headers:

| Header                   | Type    | Required | Meaning                                                                |
|--------------------------|---------|----------|------------------------------------------------------------------------|
| `x-rewritten-messages`   | string  | one of   | JSON-encoded rewritten `messages` array (the array forwarded upstream). Use this when the array fits in a header (most browsers/servers tolerate ~8–16 KB). |
| `x-rewritten-sidecar`    | string  | one of   | Filesystem path to a JSON file holding the rewritten `messages` array. Use when the inline form would exceed ~8 KB. The file MUST be readable by the replay process (so write under `~/.cache/qwen-compact/debug/<request-id>.json` or similar). |
| `x-rewrite-stats`        | string  | yes      | JSON object: `{"orig_tokens": int, "rewritten_tokens": int, "elided_tool_result_ids": [string, ...]}`. Token counts SHOULD come from `llama-server`'s `/tokenize` endpoint, not estimates. |

If neither `x-rewritten-messages` nor `x-rewritten-sidecar` is set, replay
falls back to a 4-chars-per-token estimate over the original body and reports
zero savings. That is degraded mode; please set one.

### Stub format for elided tool results

Per §6 Tier 1, elided tool results are replaced inline with a stub of the
form:

```
<tool_result id="t12" tool="Read" args={path:"foo.py"} bytes=14823
 first_lines="def main():\n    parser = argparse.ArgumentParser()..." />
```

`replay.py` recognizes the `id="..."` attribute and uses it as a fallback
source of elided IDs when `x-rewrite-stats.elided_tool_result_ids` is absent.

---

## replay.py

Replays a real (or synthetic) session JSONL through the proxy and diffs the
rewritten request against the original.

```bash
python3 replay.py \
    --target http://localhost:11500/v1/chat/completions \
    --session path/to/session.jsonl \
    [--max 50] \
    [--timeout 30] \
    [--out report.json]
```

Each line of `session.jsonl` is a complete `/v1/chat/completions` request
body (the `messages` field carries the cumulative history at that turn).

Output:

- A per-request table — original message count, rewritten message count,
  original tokens, rewritten tokens, delta, percent saved, number of
  elided tool-result IDs, and any error.
- A totals line.
- Optional JSON dump (`--out report.json`) for tracking watermark/prompt
  tuning across runs.

Exit code is 0 only if every request succeeded.

### Recommended workflow

1. Run the proxy in **shadow** mode (§8.4) so the upstream model sees the
   original request — replay observes only the rewrite the proxy *would*
   have applied.
2. Capture a real session (e.g. tee `/v1/chat/completions` bodies into a
   JSONL file from your editor's request logs).
3. Replay weekly as you tune watermarks (§5) and compaction prompts (§6).

---

## needle.py

Generates the synthetic 50-turn needle fixture and grades model responses.

### Generate the fixture (deterministic)

```bash
python3 needle.py generate --out fixtures/needle_50turns.jsonl
```

- Turn 1: user plants the project ID `proj-7B3Q-9` and secret token
  `tok-AABBCC`. Assistant acknowledges.
- Turns 2-49: 48 unrelated coding-chatter turns with fake `Read` / `Bash`
  tool calls and results. Volume, not signal.
- Turn 50: user asks for both planted facts.

The fixture is byte-deterministic — same script run produces the same file
(seed = `0xC0FFEE`).

### Verify a model response

After replaying the fixture through the proxy + a real model, capture the
turn-50 reply(s) into a JSON file and grade:

```bash
python3 needle.py verify --responses model_replies.json
```

Accepted shapes for `model_replies.json`:

- A bare string.
- `{"content": "..."}`
- A raw chat-completion: `{"choices": [{"message": {"content": "..."}}]}`
- A list of any of the above (one entry per run, useful for variance).

Grading is a regex match against the planted strings. Both must appear for a
response to pass. Exit code is 0 iff every response passed.

---

## fixtures/

| File                                  | What it is                                                |
|---------------------------------------|-----------------------------------------------------------|
| `needle_50turns.jsonl`                | The deterministic needle fixture (committed).             |
| `decision_preservation_README.md`     | Instructions for the human-curated decision eval (§8.3).  |

Real sessions for the decision eval are NOT committed — see the README in
`fixtures/` for the rationale and the labeling format expected.

---

## What this harness does not do

- It does not call any LLM. Replay only inspects the proxy's rewrites;
  needle only generates fixtures and grades pre-captured responses. The
  proxy team (or a separate runner) is responsible for actually invoking
  the model when an end-to-end needle pass is wanted.
- It does not implement the decision-preservation eval beyond the
  placeholder.
- It does not measure latency or KV-cache reuse — that belongs in
  `phase 3` instrumentation (§9).
