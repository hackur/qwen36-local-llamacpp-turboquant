#!/usr/bin/env python3
"""Tier-4 fallback compactor: extractive summarization via sumy.

See docs/compaction-strategy.md, especially:
  - Section 3.4 (extractive summarization survey)
  - Section 6 Tier 4 (where this fits in the proxy pipeline)
  - Section 13 Appendix A (the original spike that prompted this)

This is a standalone CLI. The proxy shells out to it when its preferred
small-model summarizer (Tier 3) is unavailable.

Protocol
--------
stdin:  one JSON object:
        {
          "messages": [{"role": "user|assistant|system|tool", "content": "..."}],
          "previous_summary": "" | "<verbatim prior summary block>",
          "token_budget": 1500,
          "algorithm": "lexrank" | "lsa" | "textrank"
        }
stdout: plain UTF-8 text. The summary block, ready to drop straight into a
        <summary>...</summary> wrapper by the proxy. No surrounding tags.

Exit codes
----------
  0 — success (stdout may be empty if there was nothing to summarize)
  2 — failure (stdout is empty; stderr has the reason). The proxy treats this
      as "fall through to hard truncate"; it must be distinguishable from a
      legitimate empty success at exit 0.

Determinism
-----------
Given the same input we produce the same output. sumy is deterministic for
LexRank/LSA/TextRank when the input string is fixed and we don't shuffle
sentences. We never call out to the network and never invoke an LLM.

NLTK data
---------
sumy needs the NLTK 'punkt' (and 'punkt_tab' on newer NLTK) tokenizer data.
First-time install (offline-friendly: do this once with network, then it's
cached under ~/nltk_data):

    python3 -m nltk.downloader punkt punkt_tab

If the data is missing at runtime we exit 2 with a clear error rather than
silently degrading.
"""

from __future__ import annotations

import json
import re
import sys
import traceback
from typing import Iterable

# ~4 chars/token is the well-known OpenAI-tokenizer rule of thumb for English
# prose; close enough for budgeting against any modern BPE tokenizer (Qwen,
# Llama, GPT). The proxy is the source of truth on real token counts via
# llama-server /tokenize — this estimator only needs to be in the right
# ballpark to pick "enough but not too many" sentences.
CHARS_PER_TOKEN = 4


def estimate_tokens(text: str) -> int:
    if not text:
        return 0
    return max(1, len(text) // CHARS_PER_TOKEN)


# Patterns we strip BEFORE handing text to sumy. sumy's sentence ranking
# treats every clause as candidate prose, so JSON tool payloads and code
# fences end up with high LexRank scores and the summary becomes a salad of
# braces. See docs/compaction-strategy.md §3.4 / §A.2 for the rationale.
_FENCE_RE = re.compile(r"```.*?```", re.DOTALL)
_INLINE_CODE_RE = re.compile(r"`[^`]*`")
_TOOL_TAG_RE = re.compile(
    r"<tool_(?:call|result|use)\b[^>]*?(?:/>|>.*?</tool_(?:call|result|use)>)",
    re.DOTALL | re.IGNORECASE,
)
_JSONISH_RE = re.compile(r"\{[^{}]*\}", re.DOTALL)
_WS_RE = re.compile(r"[ \t]+")
_BLANK_RE = re.compile(r"\n{3,}")


def _scrub(text: str) -> str:
    """Strip code fences, tool-call/result tags, inline JSON-ish payloads."""
    if not text:
        return ""
    text = _FENCE_RE.sub(" ", text)
    text = _TOOL_TAG_RE.sub(" ", text)
    text = _INLINE_CODE_RE.sub(" ", text)
    # Multi-pass JSON squash — handles a few levels of nesting cheaply.
    for _ in range(3):
        new = _JSONISH_RE.sub(" ", text)
        if new == text:
            break
        text = new
    text = _WS_RE.sub(" ", text)
    text = _BLANK_RE.sub("\n\n", text)
    return text.strip()


def _content_to_text(content) -> str:
    """OpenAI chat content can be str or a list of parts. Coerce to str."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        out = []
        for part in content:
            if isinstance(part, dict):
                if part.get("type") in ("text", "input_text", "output_text"):
                    out.append(str(part.get("text", "")))
                # tool_use / tool_result / image / etc. are dropped.
            elif isinstance(part, str):
                out.append(part)
        return "\n".join(out)
    return ""


def extract_prose(messages: Iterable[dict]) -> str:
    """Return concatenated prose from user/assistant messages only.

    System messages are excluded (Tier 0 keeps them verbatim). Tool messages
    are excluded entirely (Tier 1 handles those). Assistant messages with
    tool_calls have the tool_calls dropped — we keep only the prose.
    """
    chunks = []
    for m in messages:
        if not isinstance(m, dict):
            continue
        role = m.get("role")
        if role not in ("user", "assistant"):
            continue
        # If the assistant message has tool_calls, the visible prose is in
        # `content`; tool_calls live in their own field which we skip.
        text = _content_to_text(m.get("content", ""))
        text = _scrub(text)
        if text:
            chunks.append(text)
    return "\n\n".join(chunks).strip()


def _build_summarizer(algorithm: str):
    from sumy.summarizers.lex_rank import LexRankSummarizer
    from sumy.summarizers.lsa import LsaSummarizer
    from sumy.summarizers.text_rank import TextRankSummarizer
    from sumy.nlp.stemmers import Stemmer
    from sumy.utils import get_stop_words

    algorithm = (algorithm or "lexrank").lower()
    stemmer = Stemmer("english")
    if algorithm == "lsa":
        s = LsaSummarizer(stemmer)
    elif algorithm == "textrank":
        s = TextRankSummarizer(stemmer)
    else:
        s = LexRankSummarizer(stemmer)
    s.stop_words = get_stop_words("english")
    return s


def summarize(prose: str, token_budget: int, algorithm: str) -> str:
    """Run sumy and greedily pick top-ranked sentences within the budget."""
    if not prose:
        return ""
    from sumy.parsers.plaintext import PlaintextParser
    from sumy.nlp.tokenizers import Tokenizer

    parser = PlaintextParser.from_string(prose, Tokenizer("english"))

    # Fast path: if the whole prose already fits inside the budget there is
    # nothing to extract — pass it through verbatim. Without this the
    # n_request heuristic below can ask sumy for a single sentence on tiny
    # inputs and silently drop the rest, even though the budget allows it.
    sentences = list(parser.document.sentences)
    if not sentences:
        return ""
    if estimate_tokens(prose) <= token_budget:
        return " ".join(str(s).strip() for s in sentences if str(s).strip())

    summarizer = _build_summarizer(algorithm)

    # Ask sumy for many sentences; we'll stop greedily once we hit the budget.
    # The cap (200) prevents pathological docs from spending forever ranking.
    # Floor at the actual sentence count so we never under-request on docs
    # whose char-count happens to be small relative to the 80-char heuristic.
    n_request = min(200, max(len(sentences), len(prose) // 80, 1))
    ranked = summarizer(parser.document, n_request)

    picked = []
    used = 0
    for sent in ranked:
        s = str(sent).strip()
        if not s:
            continue
        cost = estimate_tokens(s) + 1  # +1 for the joining space/newline
        if used + cost > token_budget:
            # Try one more in case it's tiny enough to slot in.
            if cost > token_budget // 4:
                break
            continue
        picked.append(s)
        used += cost
    return " ".join(picked).strip()


def compose(previous_summary: str, body: str) -> str:
    """Concatenate prior summary verbatim above the new body.

    Per §A.5 open question, default policy is "keep previous summary
    verbatim, do NOT re-summarize". This avoids the recursive-summary drift
    that Sigalovski's Compaction Memory gist documents (agents behaving 'as
    if the session just started' after 2-3 compactions).
    """
    parts = []
    if previous_summary:
        parts.append(previous_summary.strip())
    if body:
        parts.append(body.strip())
    return "\n\n".join(p for p in parts if p)


def main() -> int:
    try:
        raw = sys.stdin.read()
        if not raw.strip():
            print("compact.py: empty stdin", file=sys.stderr)
            return 2
        payload = json.loads(raw)
        messages = payload.get("messages") or []
        previous_summary = payload.get("previous_summary") or ""
        token_budget = int(payload.get("token_budget") or 1500)
        algorithm = payload.get("algorithm") or "lexrank"

        if token_budget <= 0:
            print("compact.py: token_budget must be positive", file=sys.stderr)
            return 2

        # Reserve room for the previous summary — it is verbatim and counts
        # against the same budget.
        prev_cost = estimate_tokens(previous_summary)
        remaining = max(0, token_budget - prev_cost)

        prose = extract_prose(messages)
        body = summarize(prose, remaining, algorithm) if remaining > 0 else ""
        result = compose(previous_summary, body)

        sys.stdout.write(result)
        sys.stdout.flush()
        return 0
    except Exception as exc:  # noqa: BLE001 — by design: never crash the proxy
        # Empty stdout, non-zero exit. Proxy falls through to hard truncate.
        sys.stderr.write(f"compact.py: {type(exc).__name__}: {exc}\n")
        sys.stderr.write(traceback.format_exc())
        return 2


if __name__ == "__main__":
    sys.exit(main())
