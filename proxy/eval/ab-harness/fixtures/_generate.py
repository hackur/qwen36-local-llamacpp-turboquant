#!/usr/bin/env python3
"""_generate.py — synthesize the 5 ab-harness fixture sessions.

Run once to (re)generate the .jsonl files in this directory. The output is
deterministic (no RNG). All content is purely synthetic — no real user data.

Each fixture embeds:
  - One labeled "needle" span: a message with content beginning with
    "NEEDLE[<id>]: <fact>". The harness scores `needle_recovery=1` if the
    needle text survives compaction in the rewritten prompt.
  - Where applicable, AGREED / D-NN decision markers in assistant turns.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

HERE = Path(__file__).resolve().parent

LOREM = (
    "The orchestration layer routes requests through the broker and the "
    "consumer commits offsets after each batch. Backpressure is handled by "
    "the upstream queue and recovered via dead-letter retries with bounded "
    "exponential delays. "
)

BASH_OUT = "\n".join(
    f"[{i:04d}] /var/log/app/worker-{i%4}.log  {os.urandom(0).hex()}  "
    f"line={i} status={'OK' if i % 7 else 'WARN'} latency_ms={(i * 13) % 800} "
    f"path=/api/v{i % 3}/items/{i * 17}"
    for i in range(380)
)

DIFF_BLOB = """diff --git a/src/worker.py b/src/worker.py
index aaaaaaa..bbbbbbb 100644
--- a/src/worker.py
+++ b/src/worker.py
@@ -10,7 +10,8 @@ class Worker:
-        self.timeout = 30
+        # raised after incident IR-2026-04-12; see runbook
+        self.timeout = 90
         self.retry = 3

@@ -42,6 +43,9 @@ def consume(self, batch):
-        return self._handle(batch)
+        with tracer.span("consume", batch_id=batch.id):
+            return self._handle(batch)
""" * 6


def write(path: Path, rows: list[dict]):
    with path.open("w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    sz = path.stat().st_size
    print(f"  {path.name}: {len(rows)} rows, {sz} bytes")


# ---------- tool-heavy ----------
def gen_tool_heavy():
    rows = []
    rows.append({"role": "system", "content": "You are a debugging assistant with shell, grep, and read_file tools."})
    rows.append({"role": "user", "content": "The deploy is failing on host worker-3. Investigate."})
    rows.append({
        "role": "assistant",
        "content": "Checking logs first.",
        "tool_calls": [{"id": "tc_001", "type": "function",
                        "function": {"name": "bash", "arguments": json.dumps({"cmd": "tail -n 400 /var/log/app/worker-3.log"})}}],
    })
    rows.append({"role": "tool", "tool_call_id": "tc_001", "name": "bash", "content": BASH_OUT})
    rows.append({"role": "assistant", "content": "I see warn lines. Pulling the config file."})
    rows.append({
        "role": "assistant", "content": "",
        "tool_calls": [{"id": "tc_002", "type": "function",
                        "function": {"name": "read_file", "arguments": json.dumps({"path": "/etc/app/worker.yaml"})}}],
    })
    rows.append({"role": "tool", "tool_call_id": "tc_002", "name": "read_file",
                 "content": "NEEDLE[tool-heavy-01]: the worker config sets retry_backoff_ms=4500 in production.\n" + (LOREM * 30)})
    rows.append({
        "role": "assistant", "content": "",
        "tool_calls": [{"id": "tc_003", "type": "function",
                        "function": {"name": "grep", "arguments": json.dumps({"pattern": "retry_backoff", "path": "/etc/app/"})}}],
    })
    rows.append({"role": "tool", "tool_call_id": "tc_003", "name": "grep", "content": (LOREM * 60)})
    rows.append({
        "role": "assistant", "content": "",
        "tool_calls": [{"id": "tc_004", "type": "function",
                        "function": {"name": "bash", "arguments": json.dumps({"cmd": "systemctl status app-worker"})}}],
    })
    rows.append({"role": "tool", "tool_call_id": "tc_004", "name": "bash", "content": (LOREM * 50)})
    rows.append({"role": "user", "content": "What backoff value did the config use?"})
    rows.append({"role": "assistant", "content": "Per the worker.yaml read above, retry_backoff_ms=4500."})
    # Pad with prose turns so middle tool_results fall outside the verbatim
    # keep window and Tier 1 has more candidates to stub.
    for i in range(6):
        rows.append({"role": "user", "content": f"Anything else worth noting? ({i})"})
        rows.append({"role": "assistant", "content": f"Note {i}: " + (LOREM * 2)})
    return rows


# ---------- chit-chat ----------
def gen_chit_chat():
    rows = [{"role": "system", "content": "You are a friendly assistant."}]
    topics = [
        "weekend plans", "the weather", "a movie recommendation", "coffee preferences",
        "running shoes", "podcasts", "houseplants", "keyboard layouts",
        "city walks", "lunch ideas", "headphone choices", "book series",
        "morning routines", "cycling routes", "tea vs coffee",
    ]
    for i, t in enumerate(topics):
        rows.append({"role": "user", "content": f"Let's talk about {t}. What do you think?"})
        if i == 7:
            rows.append({"role": "assistant",
                         "content": f"NEEDLE[chit-chat-01]: my favorite imaginary cafe is named Lumen-on-Ash and it opens at 0630.\nAlso, {t} is a nice topic. " + LOREM})
        else:
            rows.append({"role": "assistant", "content": f"Re: {t}. " + (LOREM * 2)})
    rows.append({"role": "user", "content": "Cool. Any final thought?"})
    rows.append({"role": "assistant", "content": "Stay curious. " + LOREM})
    return rows


# ---------- decision-heavy ----------
def gen_decision_heavy():
    rows = [{"role": "system", "content": "You facilitate architecture review meetings; record decisions explicitly."}]
    rows.append({"role": "user", "content": "Should we keep Postgres or move analytics to Clickhouse?"})
    rows.append({"role": "assistant", "content": "AGREED [D-01]: keep Postgres for OLTP; introduce Clickhouse only for analytics tables exceeding 50M rows. " + LOREM})
    rows.append({"role": "user", "content": "What about retention?"})
    rows.append({"role": "assistant", "content": "AGREED [D-02]: retention is 90 days hot, 365 cold; cold tier is S3 Glacier. " + LOREM})
    rows.append({"role": "user", "content": "Open question: who owns the migration runbook?"})
    rows.append({"role": "assistant", "content": "UNRESOLVED [D-03]: ownership pending — platform team to nominate by Friday. " + LOREM})
    rows.append({"role": "user", "content": "And the rollback plan?"})
    rows.append({"role": "assistant",
                 "content": "NEEDLE[decision-heavy-01]: rollback uses snapshot tag rb-2026-05-07-T1 stored in s3://infra-snapshots/rb/.\nAGREED [D-04]: rollback contract documented above. " + LOREM})
    rows.append({"role": "user", "content": "Costs?"})
    rows.append({"role": "assistant", "content": "AGREED [D-05]: monthly budget cap $4,200 for Clickhouse cluster. " + LOREM})
    rows.append({"role": "user", "content": "Any unresolved follow-ups?"})
    rows.append({"role": "assistant", "content": "UNRESOLVED [D-06]: Q3 capacity review scheduled but date TBD. " + LOREM})
    rows.append({"role": "user", "content": "Summarize the agreed decisions please."})
    rows.append({"role": "assistant", "content": "AGREED items: D-01 OLTP/analytics split, D-02 retention, D-04 rollback, D-05 budget. UNRESOLVED: D-03 owner, D-06 capacity review. " + LOREM})
    rows.append({"role": "user", "content": "Anything else?"})
    rows.append({"role": "assistant", "content": "AGREED [D-07]: all decisions recorded in runbooks/arch/2026-05-07.md. " + LOREM})
    rows.append({"role": "user", "content": "Thanks."})
    rows.append({"role": "assistant", "content": "Done. " + LOREM})
    return rows


# ---------- code-review ----------
def gen_code_review():
    rows = [{"role": "system", "content": "You review Python diffs and produce structured comments."}]
    rows.append({"role": "user", "content": "Please review this diff."})
    rows.append({
        "role": "assistant", "content": "Reading the diff via tool.",
        "tool_calls": [{"id": "tc_cr_1", "type": "function",
                        "function": {"name": "read_file", "arguments": json.dumps({"path": "PR-482.diff"})}}],
    })
    rows.append({"role": "tool", "tool_call_id": "tc_cr_1", "name": "read_file", "content": DIFF_BLOB})
    rows.append({"role": "assistant",
                 "content": "Comment 1 [src/worker.py:13]: timeout raised 30->90; AGREED [CR-01] acceptable given IR-2026-04-12. " + LOREM})
    rows.append({"role": "user", "content": "What about the tracer span?"})
    rows.append({"role": "assistant",
                 "content": "Comment 2 [src/worker.py:46]: tracer.span wraps consume; AGREED [CR-02] add a test covering exception path. " + LOREM})
    rows.append({"role": "user", "content": "Run the linter."})
    rows.append({
        "role": "assistant", "content": "",
        "tool_calls": [{"id": "tc_cr_2", "type": "function",
                        "function": {"name": "bash", "arguments": json.dumps({"cmd": "ruff check src/"})}}],
    })
    rows.append({"role": "tool", "tool_call_id": "tc_cr_2", "name": "bash",
                 "content": "NEEDLE[code-review-01]: ruff reported zero violations on commit 9a1b2c3 of branch fix/timeout.\n" + (LOREM * 25)})
    rows.append({"role": "user", "content": "Tests?"})
    rows.append({
        "role": "assistant", "content": "",
        "tool_calls": [{"id": "tc_cr_3", "type": "function",
                        "function": {"name": "bash", "arguments": json.dumps({"cmd": "pytest -q"})}}],
    })
    rows.append({"role": "tool", "tool_call_id": "tc_cr_3", "name": "bash", "content": (LOREM * 80)})
    rows.append({"role": "assistant",
                 "content": "Comment 3: tests pass. UNRESOLVED [CR-03]: missing changelog entry. " + LOREM})
    rows.append({"role": "user", "content": "Fix the changelog and re-run."})
    rows.append({"role": "assistant", "content": "Suggesting changelog text and re-checking. AGREED [CR-04]: ship after changelog patch. " + LOREM})
    rows.append({"role": "user", "content": "Approved?"})
    rows.append({"role": "assistant", "content": "Approved pending CR-03. " + LOREM})
    # Pad with prose turns so the early big tool_result lands outside both
    # the 8-turn AND the 8000-token verbatim-keep window (tier1 only stubs
    # evictable messages — both thresholds must be met from the tail).
    for i in range(10):
        rows.append({"role": "user", "content": f"Follow-up {i}: any nits to file?"})
        rows.append({"role": "assistant", "content": f"Nit {i}: minor. " + (LOREM * 4)})
    return rows


# ---------- mixed-prose-tool ----------
def gen_mixed():
    rows = [{"role": "system", "content": "You alternate between prose summarization and tool invocations."}]
    rows.append({"role": "user", "content": "Summarize the incident timeline and gather metrics."})
    rows.append({"role": "assistant",
                 "content": "Prose summary part 1: incident IR-2026-04-12 began at 03:14 UTC. " + (LOREM * 10)})
    rows.append({
        "role": "assistant", "content": "",
        "tool_calls": [{"id": "tc_mp_1", "type": "function",
                        "function": {"name": "metrics", "arguments": json.dumps({"q": "p99_latency"})}}],
    })
    rows.append({"role": "tool", "tool_call_id": "tc_mp_1", "name": "metrics", "content": (LOREM * 40)})
    rows.append({"role": "assistant",
                 "content": "Prose summary part 2: latency degraded to p99=2400ms peaking at 03:42. " + (LOREM * 10)})
    rows.append({
        "role": "assistant", "content": "",
        "tool_calls": [{"id": "tc_mp_2", "type": "function",
                        "function": {"name": "metrics", "arguments": json.dumps({"q": "error_rate"})}}],
    })
    rows.append({"role": "tool", "tool_call_id": "tc_mp_2", "name": "metrics",
                 "content": "NEEDLE[mixed-prose-tool-01]: peak error rate during the incident reached 14.7 percent at 03:42 UTC.\n" + (LOREM * 30)})
    rows.append({"role": "assistant",
                 "content": "Prose summary part 3: error rate confirms saturation hypothesis. " + (LOREM * 10)})
    rows.append({
        "role": "assistant", "content": "",
        "tool_calls": [{"id": "tc_mp_3", "type": "function",
                        "function": {"name": "logs", "arguments": json.dumps({"q": "ERROR worker"})}}],
    })
    rows.append({"role": "tool", "tool_call_id": "tc_mp_3", "name": "logs", "content": (LOREM * 50)})
    rows.append({"role": "assistant",
                 "content": "Prose part 4: AGREED [MX-01] to file postmortem template. " + (LOREM * 8)})
    rows.append({"role": "user", "content": "Final report?"})
    rows.append({"role": "assistant", "content": "Final: see needle and AGREED above. " + (LOREM * 5)})
    # Pad so early oversized tool_results escape both the 8-turn and 8000-tok
    # verbatim-keep windows (both thresholds must be met from the tail).
    for i in range(10):
        rows.append({"role": "user", "content": f"And the {i}-th follow-up question?"})
        rows.append({"role": "assistant", "content": f"Answer {i}: " + (LOREM * 5)})
    return rows


def main():
    fixtures = {
        "tool-heavy.jsonl": gen_tool_heavy(),
        "chit-chat.jsonl": gen_chit_chat(),
        "decision-heavy.jsonl": gen_decision_heavy(),
        "code-review.jsonl": gen_code_review(),
        "mixed-prose-tool.jsonl": gen_mixed(),
    }
    print(f"writing {len(fixtures)} fixtures into {HERE}")
    for name, rows in fixtures.items():
        write(HERE / name, rows)


if __name__ == "__main__":
    main()
