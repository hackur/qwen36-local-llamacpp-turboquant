# Compaction Strategy for Local Agentic Sessions

A research-backed plan for keeping long-running coding-agent sessions coherent on
this stack — **Qwen 3.6-35B-A3B (or alternates) on llama.cpp + TurboQuant, M3 Max
64 GB, fully offline-capable** — without requiring the agent harness (OpenClaw,
Continue, OpenCode, Zed, etc.) to know that compaction is happening.

The thesis: **compaction belongs in a thin proxy between the harness and
`llama-server`**. The harness keeps speaking vanilla OpenAI Chat Completions; the
proxy quietly rewrites the message array before forwarding. Everything runs on the
same Mac, fully offline. No remote model required.

This is the design doc. The original sumy-based spike that prompted this work
is folded in as Appendix A (§13) and surfaces in the pipeline as the Tier-4
fallback.

---

## 1. Why compact at all

Three forces push every long agent session toward failure:

1. **Hard context cap.** Even with turbo3 KV at ~10–15 KB/tok we top out around
   128–192K tokens on a 64 GB Mac (see [`context-matrix.md`](context-matrix.md)).
   Past that we OOM or fall back to CPU.
2. **Context rot.** Empirically, retrieval and reasoning quality degrade well
   before the hard cap. Chroma's "Context Rot" study and Anthropic's context-
   engineering writeup both report sharp drops in real-task accuracy long before
   needle-in-a-haystack starts to fail. With ~500 tokens of relevant code in 20K
   tokens of session, signal-to-noise is ~2.5% — the model spreads its attention
   thin and starts hallucinating or repeating earlier mistakes.
3. **Cost-per-step (local edition).** Tokens here are CPU-cheap but **time-
   expensive**: prompt processing on a 100K context is several seconds even at
   ~322 tok/s prefill, and that latency multiplies across an agentic loop. Less
   junk in context = more turns per minute.

So compaction is not just for hitting limits — it's a quality-and-throughput
tool that should fire long before we're full.

---

## 2. Where to put compaction

Five layers can host compaction logic. Ranked by "least invasive to the harness":

| Layer | Pros | Cons | Verdict |
|---|---|---|---|
| **Harness/agent (OpenClaw)** | Sees the full agent loop, has tool-call semantics natively | Requires a plugin per harness; harness may not expose the hook offline (this is the problem the user is trying to avoid) | Skip for our case |
| **Reverse proxy in front of `llama-server`** | Transparent to any OpenAI-compatible client; one implementation works for every editor; can read & rewrite messages and tools | Has to reconstruct semantics from the message array; doesn't see "what the agent intended" | **Primary recommendation** |
| **`llama-server` itself** (cache reuse, KV shifting, slot save/restore) | Native, fastest possible | Operates on tokens not semantics; can't decide *what* to drop, only *how* to avoid recomputing | **Use as accelerator under the proxy** |
| **A modified `llama-server` fork** | Could push compaction inside the prefill | Fork burden, breaks our ability to swap binaries | No |
| **Sidecar memory store** (MemGPT-style external archive) | Persistent across sessions | Requires the agent to call new tools — defeats "transparent" | Useful as an **opt-in companion**, not the core |

The architecture below builds the proxy, treats `llama-server`'s native cache as
a performance layer underneath it, and offers an opt-in MemGPT-style archive as a
later phase.

---

## 3. Survey of compaction techniques

What the field is actually doing, with applicability notes for this stack.

### 3.1 LLM-based recursive summarization (MemGPT, "Recursively Summarizing Enables Long-Term Dialogue Memory")

The canonical pattern: when the window fills, evict old turns, summarize them
together with the *previous* summary, prepend the new summary, continue.

- **Pros:** Highest semantic quality. Captures decisions, plans, the narrative arc.
- **Cons:** Costs another model call per compaction. Drift across recursions —
  Sigalovski's "Compaction Memory" gist documents agents behaving "as if the
  session just started" after 2–3 compactions.
- **Local-stack fit:** Excellent, *if* we don't block the main model. Solution
  below: run a **small second model on a second port** (e.g. `gemma4-e4b` Q8_0,
  ~8 GB, ~51 tok/s, or `nemotron-4b` Q4 at ~98 tok/s) as the summarizer. The
  primary 35B keeps generating; the proxy talks to the small model out-of-band.

### 3.2 Tool-result clearing (Anthropic's "lightest touch" compaction)

Anthropic's context-engineering guide and Claude's developer-platform feature both
argue tool outputs are the cheapest tokens to drop: agents rarely re-read old
`Read` or `Bash` results, and replacing each with a stub like
`<tool_result id="t12" elided="3421 tokens, see notes/t12.txt"/>` is essentially free.

- **Pros:** No ML required. Deterministic. Reversible (the proxy can keep the
  original on disk and re-inject if a later turn references it).
- **Cons:** Misses prose-heavy compaction (the assistant's own narration).
- **Verdict:** **First thing to ship.** Compresr's "Context Gateway" is built
  around exactly this idea, with a phantom `expand_context` tool the agent can
  call to rehydrate. We can copy that pattern.

### 3.3 Token-level compression (LLMLingua / LLMLingua-2)

A small model (GPT2-small / BERT-class) drops low-perplexity tokens from the
prompt, claiming up to 20× compression at acceptable quality.

- **Pros:** Works on any text; very fast (LLMLingua-2 is 3–6× faster still).
- **Cons:** **CompressionAttack (arXiv 2510.22963)** showed adversarial inputs
  can manipulate the compressor in agent settings. More importantly, perplexity-
  based dropping mangles structured payloads — JSON tool results, file paths,
  diffs — exactly the content we have most of.
- **Verdict:** Useful as a layer for assistant prose only, *after* tool-result
  clearing and *before* full LLM summarization. Optional.

### 3.4 Extractive summarization (sumy: LexRank, LSA, TextRank)

What the original spike proposed. Picks representative sentences verbatim.

- **Pros:** Zero-cost, deterministic, no model.
- **Cons:** Bad on structured content; picks JSON fragments. Better than nothing
  for prose-heavy turns.
- **Verdict:** Reasonable last-resort fallback when the small summarizer model
  isn't loaded. Demote relative to the first plan.

### 3.5 Structured note-taking (Claude Code, "NOTES.md" pattern)

Anthropic explicitly calls this out alongside compaction: have the agent
periodically write to a notes file outside context, and pull relevant notes back
in on demand.

- **Pros:** Persistent across sessions and across compactions. The agent owns
  its own memory.
- **Cons:** Requires harness cooperation — *unless* the proxy injects a phantom
  `note_write`/`note_read` tool. Same trick as Compresr's `expand_context`.
- **Verdict:** Phase 2. Powerful but adds tool surface; ship without it first.

### 3.6 Sub-agent decomposition

Spawn a worker sub-agent for a bounded sub-task with its own clean context;
return only the result to the manager.

- **Pros:** Each sub-task starts fresh — no rot accumulation. Anthropic, LangChain
  Deep Agents, and Microsoft Agent Framework all converge on this.
- **Cons:** Requires harness support. Doesn't fit the "invisible to the
  harness" constraint.
- **Verdict:** Out of scope for the proxy. Note it in the limits section.

### 3.7 KV-cache-level tricks (llama.cpp native)

`llama-server` already has machinery we should exploit *underneath* whatever we
do at the message layer:

- `--cache-reuse N` with KV shifting reuses any prefix ≥ N tokens that matches
  cached state. This is what makes long sessions tolerable today — it means a
  rewritten message array still benefits from cached prefix when only the tail
  changed.
- **Host-memory prompt caching** (covered in `llama.cpp` discussion #20574)
  spills KV from VRAM to system RAM. On unified-memory Apple Silicon this is
  less of a win than on discrete GPUs, but it still matters when we're juggling
  multiple slots (primary 35B + summarizer e4b on one box).
- `/slots/<id>/save` + `/slots/<id>/restore` with `--slot-save-path` write KV to
  disk. This is how we **resume a long session days later** without re-prefilling
  100K tokens. ~hundreds of MB per slot file; restore is near-instant.

These are necessary plumbing for the proxy strategy below, not alternatives to it.

---

## 4. Recommended architecture

```
                                                    ┌────────── small summarizer ──────────┐
                                                    │  llama-server :10503                  │
                                                    │  gemma4-e4b Q8_0 / nemotron-4b        │
                                                    │  16K ctx, single slot                 │
                                                    └──────────────────────────────────────┘
                                                                     ▲
                                                                     │ background HTTP
                                                                     │
   OpenClaw / Continue / Zed ──► localhost:11500 ──► COMPACT-PROXY ──┼──► llama-server :10501
       (any OpenAI client)        (Node.js or Go)                    │     primary 35B turbo3
                                                                     │     128K ctx
                                                                     ▼
                                                          ~/.cache/qwen-compact/
                                                            ├─ tool-results/   verbatim originals (rehydrate)
                                                            ├─ notes/          structured note files
                                                            ├─ summaries/      previous summaries (TTL)
                                                            └─ slots/          --slot-save-path snapshots
```

The agent connects to the **proxy** instead of `llama-server` directly. From the
agent's perspective nothing has changed — same `/v1/chat/completions`, same
streaming, same tools. The proxy:

1. Inspects every request for token-budget watermarks (see §5).
2. Applies a **tiered compaction pipeline** (§6).
3. Forwards the rewritten request to `llama-server :10501`.
4. May, on the side, call `llama-server :10503` (the summarizer) and persist
   artifacts to `~/.cache/qwen-compact/`.
5. Streams the response back unchanged.

### Why Node.js or Go for the proxy

- Streaming SSE passthrough must be lossless and low-latency.
- Tokenization is the load-bearing operation. We need the **same tokenizer the
  primary model uses** to count budget accurately. `llama-server` exposes
  `/tokenize` — call it. Cache aggressively. Don't use `tiktoken`.
- Either runtime is fine. Node has more OpenAI-proxy reference code; Go has
  better stable streaming. Pick the one already in your toolchain.

### Why a separate summarizer model

The 35B can summarize itself, but doing so blocks the agent's main turn for the
duration. A second `llama-server` on `:10503` with `gemma4-e4b` (8 GB Q8_0,
~51 tok/s) or `nemotron-4b` (2.8 GB, ~98 tok/s) costs us ~3–8 GB of unified
memory and lets summarization run **concurrently** with the next agent turn.

Memory budget recheck on M3 Max 64 GB:
- system 6 GB + qwen36-35b weights 28.5 GB + 25 GB for KV/scratch = 59.5 GB
- Adding nemotron-4b weights (2.8 GB) + ~1 GB KV = ~3.8 GB extra
- Tight but workable. If pressured, drop the summarizer to **CPU-only** (it's
  small enough that this is fine for a background task), or run the summarizer
  on-demand by stop/starting it.

---

## 5. Triggers — when to compact

Three signals, in order of preference:

1. **Watermark by tokens.** Tokenize the incoming message array (cached). If
   the request would push the slot above a configured fraction of `n_ctx`,
   compact. Anthropic doesn't publish a number; Compresr defaults to **85%**
   of capacity. We should default to **70%** because context rot bites earlier
   than the hard cap, and because we want to fire *before* `llama-server` has
   to evict anything it could otherwise reuse via cache-reuse.

2. **Watermark by message count + age.** As a cheap fallback: if there are
   more than N (say 40) messages and the oldest non-system message is more than
   K turns ago (say 20), compact regardless of token count. Catches sessions
   where every turn is small but cumulatively bloated.

3. **Tool-result threshold.** Independent of (1)/(2): any single tool result
   over `min_tokens` (default 2000) is **always** elided to a stub the moment
   it enters the proxy. This is essentially free quality and the LangChain
   Deep Agents writeup recommends roughly the same threshold (2K tokens →
   write to disk + 10-line preview).

The proxy reads the actual context size from `llama-server`'s `/props` endpoint
on startup, so the watermark adapts to the model loaded.

---

## 6. The pipeline — what to compact, in what order

When a request crosses the watermark, run the pipeline in this order. Stop as
soon as you're under the watermark.

### Tier 0 — verbatim window (always kept)

- The system prompt.
- The last K turns (configurable; default 8 turns or 8K tokens, whichever is
  larger). This is the working set; never touch it.
- The current user turn.
- Any tool definitions. Optionally **tool-pruning** (Compresr style) — drop tool
  defs the agent hasn't used in N turns, keep an `always_keep` list. Save for
  phase 2; minor win.

### Tier 1 — tool-result elision (free, deterministic)

For every tool result older than the verbatim window:
- If `tokens(result) < min_tokens` → keep verbatim.
- Else → write the original to `~/.cache/qwen-compact/tool-results/<id>.json`,
  replace inline with a stub:
  ```
  <tool_result id="t12" tool="Read" args={path:"foo.py"} bytes=14823
   first_lines="def main():\n    parser = argparse.ArgumentParser()..." />
  ```
- Inject a phantom `expand_tool_result(id)` tool definition into the request
  (only if any stubs are present). The agent can call it to rehydrate.
  Compresr's `expand_context` is the pattern.

This single step often gets us back under the watermark and costs zero model
calls. Ship it first.

### Tier 2 — extractive index of dropped tool calls

Older messages that *contain* tool calls (not just results): rewrite them as a
compact append-only index, one line per call:

```
[t08] Read   path=src/auth.py             → 423 lines, mtime=2026-05-04T10:12
[t09] Bash   cmd="pytest tests/auth/"     → exit=1, 3 failures, see /summaries/t09.md
[t10] Edit   path=src/auth.py L88-L102    → applied
```

This is pure scripted extraction. No ML. Preserves the chain of reasoning the
agent did, in a fraction of the tokens.

### Tier 3 — prose summarization (small model, async)

For older assistant/user *prose* (text content with tool calls/results stripped),
call the summarizer on `:10503`:

- Input: previous summary (if any) + this batch of evicted prose + a fixed
  instruction (decision log style: "list architectural decisions made,
  unresolved bugs, and open questions; preserve names verbatim").
- Output: replaces the evicted prose with a single `<summary>` block.
- Cache: keyed by hash of (previous_summary + evicted_messages), 3-hour TTL —
  matches Compresr's default and dodges re-summarization on retries.

Anthropic's tuning guidance applies here: **start permissive (high recall),
tighten precision iteratively** by testing on real session traces. Save 3–5
real qwen sessions as fixtures.

### Tier 4 — fallback: extractive (sumy) or hard truncate

If the small summarizer is unavailable (not loaded, OOM, timeout):
- Run sumy LexRank with a token budget over the prose-only stream.
- Or, last resort, hard-truncate to keep only Tier 0 + Tier 2.

The proxy should **never crash a request** because compaction failed — fall
through, log, and forward whatever still fits.

---

## 7. KV-cache cooperation — making the proxy fast

A naive proxy invalidates `llama-server`'s prompt cache every time it rewrites
a message, because cache-reuse matches on prefix. We need to be careful:

- **Stable prefix.** Always emit the system prompt + summary block + tool index
  in a deterministic order, so unchanged sessions reuse cache. The summary
  block changes only when a compaction runs; between compactions, prefix is
  stable and `--cache-reuse` works.
- **Append-only tail.** Within a compaction generation, only append new
  messages; never reorder kept ones. KV shifting handles inserts at the
  boundary if `--cache-reuse N` is set with `N` ≤ a few hundred tokens (we use
  256 in `start-turboquant.sh` — verify and document).
- **Slot save on idle.** When a session has been idle for >15 min, `POST
  /slots/<id>/save` to `--slot-save-path`. On the next request for that
  session, restore before forwarding. Saves prefill on a cold session.
- **Session keying.** The proxy assigns each agent session a slot id (e.g.
  hash of system prompt + first user turn). Multiple agents on the same Mac
  get different slots; `llama-server` already supports this.

Issue #19794 (Qwen3-Coder hybrid SWA cache invalidation) is worth watching —
hybrid attention models like Qwen3-Next have bugs where cache-reuse gets
silently disabled. Our 35B-A3B is not hybrid-SWA, so we're clear today, but if
we move to a Coder-Next variant later, plan to validate.

---

## 8. Quality safeguards

The biggest risk is silent quality regression: the agent appears to work but
has lost track of an early decision. Build the following in from day one:

1. **Replay harness.** A script that takes a real session JSONL, runs it
   through the proxy, and diffs the rewritten request from the original. Lets
   us tune watermarks and prompts on real data.
2. **Needle test.** Insert a deterministic fact early in a synthetic session
   ("the user's project ID is `proj-7B3Q-9`"), run 50 turns of unrelated
   activity through compaction, then ask a question that requires the fact.
   Should pass.
3. **Decision-preservation eval.** Hand-label 5 real sessions for "what
   decisions/constraints must survive compaction." Replay through the proxy.
   Score per session. Anything <90% recall blocks shipping the compaction
   prompt.
4. **Two-stage rollout.** Proxy mode `shadow` (compute the rewritten request
   but forward the original, log diff) → `enforce`. Standard reverse-proxy
   safety pattern.
5. **Per-session opt-out.** A header (`x-compact: off`) bypasses everything.
   Use it for runs where the user wants forensic fidelity.

---

## 9. Phased build plan

**Phase 0 — instrumentation (1 day).** Stand up the proxy as a pure passthrough.
Tokenize via `/tokenize`. Log per-request token counts. Validates that we can
see what the agent is actually sending without breaking anything.

**Phase 1 — Tier 1 only (2–3 days).** Tool-result elision + `expand_tool_result`
phantom tool. No summarization. Already covers 50–80% of bloat in coding
sessions because tool outputs dominate. This alone justifies the proxy.

**Phase 2 — Tier 2 + Tier 3 (1 week).** Stand up the second `llama-server` with
`gemma4-e4b` or `nemotron-4b`. Implement the recursive summary cache and the
tool-call index. Build the replay harness in parallel.

**Phase 3 — KV cooperation (2–3 days).** Stable-prefix discipline, slot save on
idle, session keying. Measure prefill latency before/after.

**Phase 4 — structured notes + tool pruning (optional).** Phantom
`note_write`/`note_read`. Tool pruning with `always_keep` list. Skip if Phase
1–3 already deliver enough headroom.

**Phase 5 — sumy fallback (optional).** Wire the original spike's sumy script
as the Tier-3 fallback when the summarizer is offline.

---

## 10. What this does not solve

- **In-loop reasoning length.** If a single agent turn produces 50K tokens of
  thinking, we can't help — that lands in the next request as a single message.
  Mitigation is upstream (lower thinking budget, sub-agents).
- **Cross-session memory.** This proxy is per-session. For "agent remembers what
  it did last week" you want a sidecar like Letta/Mem0 on top.
- **Sub-agent orchestration.** The harness owns this. The proxy is invisible to
  the harness by design and can't dispatch sub-agents.
- **Vision/multimodal sessions.** Issue #19466 confirms slot save/restore
  doesn't yet work with vision-enabled models. Disable slot persistence on the
  vision port.
- **Adversarial inputs.** If we ever add LLMLingua-style token compression,
  CompressionAttack-class risks need a mitigation (e.g. don't run the
  compressor on tool inputs from untrusted sources).

---

## 11. Open questions

- **Watermark tuning.** 70% is a guess. Real number lives in the data once
  Phase 0 instrumentation runs for a week.
- **Summarizer model choice.** `gemma4-e4b` Q8_0 (better summaries, 8 GB) vs
  `nemotron-4b` (faster, 2.8 GB) vs `tiny` Q4 (essentially free, low quality).
  Bench all three with the decision-preservation eval.
- **Run the summarizer on CPU?** Would free GPU for the primary. The 4B model
  on CPU should still hit 10–20 tok/s, fine for background work. Worth a probe.
- **One proxy per port, or one shared proxy?** A single proxy on `:11500` that
  picks an upstream by `model` field is simplest. Tradeoff: a crash takes down
  every model. Acceptable for a personal-stack tool.
- **Persistence format.** Plain JSON in `~/.cache/qwen-compact/` is enough.
  Don't reach for SQLite unless we have a reason.

---

## 12. References

### Anthropic / industry guidance
- [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) — compaction, structured note-taking, sub-agents
- [Context engineering: memory, compaction, and tool clearing (Claude Cookbook)](https://platform.claude.com/cookbook/tool-use-context-engineering-context-engineering-tools)
- [Compaction Memory: production-tested method for Claude Code & OpenAI Codex](https://gist.github.com/sigalovskinick/e2e329bb37ecc74b9f15d5ba74ee1ee5)
- [Context Management for Deep Agents (LangChain)](https://blog.langchain.com/context-management-for-deepagents/)
- [Microsoft Agent Framework — Compaction](https://learn.microsoft.com/en-us/agent-framework/agents/conversations/compaction)
- [Google ADK — Context compression](https://google.github.io/adk-docs/context/compaction/)

### Proxy / gateway approaches
- [Compresr Context Gateway — agent proxy with phantom expand_context](https://lilting.ch/en/articles/compresr-context-gateway-agent-proxy)
- [DeepSeek V4 Flash auto-compression OpenAI-compatible proxy (gist)](https://gist.github.com/g023/c2bb7b540ffe64cee76023f18f6f9365)
- [OpenAI Cookbook — Context summarization with Realtime API](https://cookbook.openai.com/examples/context_summarization_with_realtime_api)

### Memory / summarization research
- [MemGPT: Towards LLMs as Operating Systems (arXiv 2310.08560)](https://arxiv.org/pdf/2310.08560)
- [Recursively Summarizing Enables Long-Term Dialogue Memory (arXiv 2308.15022)](https://arxiv.org/pdf/2308.15022)
- [Acon: Optimizing Context Compression for Long-horizon LLM Agents (arXiv 2510.00615)](https://arxiv.org/html/2510.00615v1)
- [Mem0: Production-Ready AI Agents with Scalable Long-Term Memory (arXiv 2504.19413)](https://arxiv.org/html/2504.19413v1)
- [Letta — Agent Memory primer](https://www.letta.com/blog/agent-memory)

### Token-level compression
- [LLMLingua (Microsoft)](https://github.com/microsoft/LLMLingua)
- [CompressionAttack — adversarial risks of prompt compression in agents (arXiv 2510.22963)](https://arxiv.org/html/2510.22963v2)

### llama.cpp specifics
- [llama-server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- [Mastering Host-Memory Prompt Caching in llama-server (discussion #20574)](https://github.com/ggml-org/llama.cpp/discussions/20574)
- [KV cache reuse with llama-server (discussion #13606)](https://github.com/ggml-org/llama.cpp/discussions/13606)
- [Persistent KV cache per session with llama-server hooks (discussion #20572)](https://github.com/ggml-org/llama.cpp/discussions/20572)
- [Issue #15082 — `--cache-reuse` regressions](https://github.com/ggml-org/llama.cpp/issues/15082)
- [Issue #19794 — Qwen3-Coder-Next hybrid SWA cache invalidation](https://github.com/ggml-org/llama.cpp/issues/19794)
- [Issue #19466 — slot save/restore broken on vision models](https://github.com/ggml-org/llama.cpp/issues/19466)

### Context rot
- [Chroma research — Context Rot](https://research.trychroma.com/context-rot)
- [Redis — Context rot explained](https://redis.io/blog/context-rot/)
- [Morph — Context Rot complete guide](https://www.morphllm.com/context-rot)

---

## 13. Appendix A — Original sumy spike

The thinking that prompted this design. Now subsumed by §3.4 (extractive
summarization) and §6 Tier 4 (fallback). Kept here for the original framing,
the plugin shape, and the open questions — most of which are still open.

### A.1 Problem (as originally framed)

When running qwen locally via llama.cpp + turboquant, sessions eventually
exceed the context window and need compaction. The default path calls a remote
LLM (e.g. Haiku) to summarize older turns. That's a non-starter when:

- We're fully offline (no network).
- We don't have / don't want to spend tokens on a remote model.
- We want a deterministic, zero-cost fallback that never crashes the session.

Local-LLM compaction (asking qwen itself to summarize) works but costs the
same context it's trying to free, and quality is uneven on long structured
transcripts.

### A.2 Idea: tiered offline compaction plugin

Use [sumy](https://github.com/miso-belica/sumy) (extractive summarization —
LexRank / LSA / TextRank) as **one layer** of a structured compaction pipeline,
not the whole solution.

The OpenClaw-style compaction provider interface is simple:
`provider.summarize(params)` returns a string, where `params` includes the
message array, instructions, and any previous summary. Returning `undefined`
auto-falls-back to LLM compaction, so the risk of plugging in a weak provider
is bounded.

#### Why sumy alone isn't enough

sumy is purely extractive — it picks representative sentences verbatim from
the source. That works for prose. Agent session transcripts are mostly **not**
prose: JSON tool results, file paths, structured payloads, multi-part messages.
Extractive ranking over that grabs random JSON fragments instead of the
narrative thread.

#### Tiered structure (original framing)

1. **Recent N turns** — kept verbatim (config: `keepRecentTokens: 8192`).
2. **Older assistant/user prose** — sumy (LexRank or LSA) over text-only
   content, tool results stripped out before ranking.
3. **Tool call index** — deterministic compact log of `tool → key args →
   result summary` for every tool call in the dropped window. No ML; pure
   extraction.
4. **File op log** — list of paths read / written / edited in the dropped
   window.

This mirrors what an LLM compactor does, minus the understanding layer. sumy
covers (2). Parts (3) and (4) are scripted extraction.

> **Note:** the main design (§6) generalizes this: Tier 0 = verbatim window,
> Tier 1 = tool-result elision, Tier 2 = tool-call index (subsumes both 3 and
> 4 above), Tier 3 = small-model summarization, Tier 4 = sumy as fallback.

### A.3 Plugin shape (if implemented as a harness plugin instead of a proxy)

```
~/.openclaw/plugins/sumy-compact/
  index.js        # registers the compaction provider, formats messages, shells to Python
  compact.py      # sumy LexRank, reads JSON from stdin, writes summary to stdout
  package.json
```

`index.js` is a thin Node wrapper: serialize the relevant slice of messages,
spawn `compact.py`, read summary from stdout, assemble the final compacted
block (prose summary + tool index + file log), return as string.

`compact.py` is small: load sumy, run LexRank with a sentence budget, print
result.

This shape was the original plan **before** we decided the proxy approach was
better (see §2 — the harness-plugin route requires a plugin per harness, and
not every harness exposes the hook offline). The same Python script is still
useful as the Tier-4 fallback the proxy shells out to.

### A.4 Expectations

- **Quality:** lower than Haiku/Sonnet compaction. Higher than nothing. Good
  enough to keep a session coherent for another few turns of work.
- **Cost:** zero tokens, ~hundreds of ms CPU.
- **Failure mode:** provider returns `undefined` on any error → falls back to
  LLM compaction → if that's also unavailable, session truncates as it would
  today. No new crash surface.

### A.5 Open questions (still open)

- Sentence budget for sumy — fixed token target vs. ratio of dropped window.
- Whether to keep the previous summary verbatim or re-summarize the union
  each time (re-summarizing drifts; keeping verbatim grows).
- Tool-result summarization heuristics: truncate to first/last N lines? Keep
  only exit codes + paths? Probably tool-specific.
- Whether qwen itself (or `gemma4-e4b` / `nemotron-4b` per §4) is a better
  Tier-3 summarizer than sumy when we have spare context budget. Almost
  certainly yes — sumy is the offline-of-last-resort fallback, not the primary.

### A.6 Status

Not built. Worth prototyping when offline robustness becomes a priority. Start
with `compact.py` + a real qwen session transcript as the test fixture, then
wire it under the proxy's Tier-4 path.

Related: [`offline-mode.md`](offline-mode.md), [`context-matrix.md`](context-matrix.md).
