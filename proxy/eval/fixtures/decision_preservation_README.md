# Decision-preservation fixtures (placeholder)

Per `docs/compaction-strategy.md` §8.3, the decision-preservation eval requires
**hand-labeled real sessions** — five of them, minimum. We deliberately do not
fabricate these: synthetic sessions don't surface the kind of subtle
architectural decisions, half-finished refactors, or buried constraints that
the real eval needs to score.

## What you (the human) need to do

For each of 5 real qwen / agent sessions:

1. Capture the raw session as `session_<N>.jsonl` in this directory. One
   `/v1/chat/completions` request body per line, same shape replay.py expects.
2. Hand-label expected outcomes in `session_<N>.labels.json`:

   ```json
   {
     "session_id": "session_1",
     "summary": "One-paragraph human summary of what the session was about.",
     "decisions": [
       {
         "id": "d1",
         "turn": 7,
         "statement": "We chose Postgres over SQLite because of concurrent writes.",
         "must_survive_through_turn": 42,
         "recall_probe": "Why did we pick Postgres?",
         "expected_substring_regex": "concurrent\\s+writes?"
       }
     ],
     "constraints": [
       {
         "id": "c1",
         "turn": 3,
         "statement": "All new endpoints must be idempotent.",
         "recall_probe": "Are endpoints idempotent?",
         "expected_substring_regex": "idempotent"
       }
     ]
   }
   ```

3. Run replay.py against the proxy. For each labeled item, send the
   `recall_probe` as a final user turn after the full session is replayed
   and check the model's reply against `expected_substring_regex`.

4. Score each session: `recalled_items / total_items`. Anything < 90% blocks
   shipping the current compaction prompt (per §8.3).

## Why no fixture is checked in

- We do not have user sessions that are safe to commit to a public repo.
- Synthesizing them would Goodhart the eval: the proxy would learn to preserve
  what we synthesized, not what real sessions actually need preserved.
- The needle test (`needle_50turns.jsonl`) covers the cheap end (one verbatim
  fact across 50 turns). The decision eval covers the expensive end
  (multi-turn reasoning, implicit constraints) and must be human-curated.

## Suggested grader (sketch — to be added under `proxy/eval/decision.py`)

Pseudocode, not implemented yet:

```
for session in sessions:
    replay through proxy in shadow mode
    for item in session.labels.decisions + session.labels.constraints:
        body = build_recall_request(session, item.recall_probe)
        send to proxy in enforce mode (real model call, this time)
        if re.search(item.expected_substring_regex, reply):
            mark recalled
    score session
```

This is left for a follow-up because it requires actually invoking the model,
which is out of scope for the harness as initially scoped.
