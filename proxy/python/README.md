# proxy/python — Tier-4 fallback compactor

Standalone CLI implementing the sumy-based extractive summarizer described
in [`docs/compaction-strategy.md`](../../docs/compaction-strategy.md)
Appendix A (§13). It is the Tier-4 fallback the proxy reaches for when the
small summarizer model on `:10503` is unavailable (not loaded, OOM, timeout
— see §6 Tier 4).

This script does not depend on the Node proxy and has no network calls.

## Install

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install -r proxy/python/requirements.txt
# One-time NLTK tokenizer data fetch (network required for this step only):
python3 -m nltk.downloader punkt punkt_tab
```

NLTK caches under `~/nltk_data` after the first download; subsequent runs
are fully offline.

## Usage

```sh
echo '{
  "messages": [
    {"role": "user", "content": "Plan compaction."},
    {"role": "assistant", "content": "We chose a thin proxy in front of llama-server. ..."}
  ],
  "previous_summary": "",
  "token_budget": 1500,
  "algorithm": "lexrank"
}' | python3 proxy/python/compact.py
```

- **stdin**: a single JSON object with `messages`, `previous_summary`,
  `token_budget`, `algorithm` (`lexrank` | `lsa` | `textrank`).
- **stdout**: plain text — drop into a `<summary>...</summary>` wrapper.
- **exit 0**: success (stdout may be empty if there was nothing to rank).
- **exit 2**: failure (stdout empty, reason on stderr). The proxy treats
  this as "fall through to hard truncate" — distinguishable from the
  legitimate empty-success case.

### Behaviour

- System and tool messages are excluded from ranking. Only `user` /
  `assistant` prose is summarized.
- Code fences, inline backticks, JSON-ish blobs, and `<tool_*>` tags are
  scrubbed before ranking — sumy mangles structured payloads (§3.4 / §A.2).
- `previous_summary` is concatenated verbatim above the new body and is
  **not** re-summarized. This is the §A.5 "keep verbatim, don't drift"
  policy: re-summarization of recursive summaries causes the agent-restart
  drift Sigalovski's Compaction Memory gist documents.
- Token budget is approximated at **~4 chars/token**. The proxy is the
  source of truth on real counts via `llama-server /tokenize`; this
  estimator only needs to be in the right ballpark to pick "enough but not
  too many" sentences.

## Test

```sh
python3 proxy/python/test_compact.py            # plain unittest
# or
pytest proxy/python/test_compact.py             # if pytest is installed
```

## Open questions (carried over from §A.5)

These are still open and will be answered with real data once the proxy is
running in `shadow` mode (§8):

- **Sentence budget shape.** Fixed token target (current default) versus a
  ratio of the dropped window. Easy to switch — both are computable from
  what the proxy passes in.
- **Verbatim vs re-summarized previous summary.** Currently verbatim. The
  alternative is re-summarizing the union, which drifts; verbatim grows.
  We may want a length cap on the previous summary that triggers a single
  re-summarization pass.
- **Tool-result heuristics.** Tier 1 owns this in the Node proxy, not us.
  Leaving the question open here for visibility.
- **sumy vs small model.** Almost certainly the small model (gemma4-e4b /
  nemotron-4b) wins when it's available; sumy is the offline-of-last-
  resort. Validate with the decision-preservation eval (§8).
- **Algorithm default.** We default to `lexrank` because it consistently
  outperforms LSA on transcript-style text in the sumy literature and is
  more stable than TextRank on short documents. Reconsider after running
  the replay harness on real qwen sessions.
