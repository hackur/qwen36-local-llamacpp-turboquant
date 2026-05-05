#!/usr/bin/env python3
"""needle.py — generate a synthetic needle-in-a-haystack session and grade
the model's recall after compaction.

Two modes:

    generate  Write a deterministic 50-turn session JSONL to --out.
              Turn 1 plants the project ID and secret token.
              Turns 2-49 are unrelated coding chatter (fake tool calls,
              file reads, bash output) — volume, not signal.
              Turn 50 asks for both planted facts.

    verify    Read a JSON file containing the model's response(s) to turn 50
              and grade them with regex against the expected strings.

The needle facts are deterministic — same script run produces byte-identical
fixtures (random.seed fixed). The fixture is meant to be replayed through the
compaction proxy with replay.py; this script does NOT itself call any LLM.

Usage:
    python3 needle.py generate --out fixtures/needle_50turns.jsonl
    python3 needle.py verify   --responses model_replies.json
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import sys
from typing import Any


# Deterministic needles. Do not change without updating verify regexes.
PROJECT_ID = "proj-7B3Q-9"
SECRET_TOKEN = "tok-AABBCC"
SEED = 0xC0FFEE
MODEL = "qwen3.6-35b-a3b"  # placeholder; proxy ignores it for fixture replay

PLANT = (
    f"FYI, the project ID is `{PROJECT_ID}` and the secret token is "
    f"`{SECRET_TOKEN}`. Please remember both for the rest of the session."
)

ASK = (
    "Two quick recall questions:\n"
    "1. What is the project ID?\n"
    "2. What is the secret token?\n"
    "Answer with just the values."
)


# Filler vocabulary — kept boring and code-shaped on purpose.
FILES = [
    "src/auth.py", "src/router.py", "src/db/models.py", "src/db/migrations.py",
    "src/utils/io.py", "src/utils/log.py", "src/api/users.py", "src/api/orders.py",
    "tests/test_auth.py", "tests/test_router.py", "tests/test_db.py",
    "scripts/build.sh", "scripts/deploy.sh", "Makefile", "pyproject.toml",
    "README.md", "docs/architecture.md", "docs/api.md",
]
BASH_CMDS = [
    "pytest -q", "ruff check .", "mypy src", "git status", "git diff --stat",
    "ls -la", "wc -l src/**/*.py", "grep -rn TODO src", "make build",
]
TOPICS = [
    "refactor the request validator", "tighten the retry policy",
    "fix the off-by-one in pagination", "improve error messages",
    "add a structured logger", "split the monolith handler",
    "review the migration script", "speed up the import time",
    "drop the unused dependency", "add a regression test",
]


def _fake_read_result(rng: random.Random, path: str) -> str:
    n = rng.randint(40, 220)
    lines = []
    for i in range(min(n, 12)):
        lines.append(f"  {i+1:4d}: # {rng.choice(['init', 'helper', 'guard', 'noop'])}_{rng.randint(0,999)}")
    return f"path={path} lines={n}\n" + "\n".join(lines) + f"\n... ({n - 12} more lines elided in fake fixture)"


def _fake_bash_result(rng: random.Random, cmd: str) -> str:
    exit_code = 0 if rng.random() > 0.15 else 1
    if cmd.startswith("pytest"):
        passed = rng.randint(20, 120)
        failed = 0 if exit_code == 0 else rng.randint(1, 4)
        return f"$ {cmd}\n{passed} passed, {failed} failed in {rng.uniform(1.2, 9.9):.2f}s\nexit={exit_code}"
    if cmd.startswith("ruff"):
        n = 0 if exit_code == 0 else rng.randint(1, 7)
        return f"$ {cmd}\nfound {n} issues\nexit={exit_code}"
    if cmd.startswith("git status"):
        return "$ git status\nOn branch main\nnothing to commit, working tree clean\nexit=0"
    return f"$ {cmd}\n(output {rng.randint(1, 30)} lines)\nexit={exit_code}"


def _busywork_pair(rng: random.Random, turn: int) -> list[dict[str, Any]]:
    """Produce one user turn + one assistant turn with embedded tool calls.

    To keep the fixture shaped like real Chat Completions traffic we use the
    OpenAI tool_calls / role=tool pattern. Each pair adds 2-3 messages.
    """
    out: list[dict[str, Any]] = []
    topic = rng.choice(TOPICS)
    out.append({
        "role": "user",
        "content": f"[turn {turn}] Can you help me {topic}?",
    })

    # 70% of assistant turns include a tool call.
    if rng.random() < 0.7:
        if rng.random() < 0.5:
            path = rng.choice(FILES)
            tc_id = f"call_{turn:03d}_r"
            out.append({
                "role": "assistant",
                "content": f"Looking at {path}.",
                "tool_calls": [{
                    "id": tc_id,
                    "type": "function",
                    "function": {"name": "Read", "arguments": json.dumps({"path": path})},
                }],
            })
            out.append({
                "role": "tool",
                "tool_call_id": tc_id,
                "name": "Read",
                "content": _fake_read_result(rng, path),
            })
        else:
            cmd = rng.choice(BASH_CMDS)
            tc_id = f"call_{turn:03d}_b"
            out.append({
                "role": "assistant",
                "content": f"Running `{cmd}`.",
                "tool_calls": [{
                    "id": tc_id,
                    "type": "function",
                    "function": {"name": "Bash", "arguments": json.dumps({"cmd": cmd})},
                }],
            })
            out.append({
                "role": "tool",
                "tool_call_id": tc_id,
                "name": "Bash",
                "content": _fake_bash_result(rng, cmd),
            })
    else:
        out.append({
            "role": "assistant",
            "content": (
                f"Sure — to {topic}, I'd start by sketching the change, then "
                f"running the test suite. No tool call needed for this step."
            ),
        })
    return out


SYSTEM_PROMPT = (
    "You are a careful local coding assistant. The user is the primary "
    "operator. Remember any facts the user explicitly asks you to remember."
)


def _build_messages(rng: random.Random) -> list[dict[str, Any]]:
    msgs: list[dict[str, Any]] = [{"role": "system", "content": SYSTEM_PROMPT}]

    # Turn 1 — plant the needle.
    msgs.append({"role": "user", "content": PLANT})
    msgs.append({
        "role": "assistant",
        "content": f"Got it — project ID `{PROJECT_ID}` and secret token `{SECRET_TOKEN}` noted.",
    })

    # Turns 2..49 — busywork.
    for turn in range(2, 50):
        msgs.extend(_busywork_pair(rng, turn))

    # Turn 50 — the recall ask. We append only the user message; the model
    # is expected to produce the answer when this body is sent.
    msgs.append({"role": "user", "content": ASK})
    return msgs


def _emit_jsonl(messages: list[dict[str, Any]], out_path: str) -> int:
    """Write one chat-completions body per line.

    Each line is a self-contained request body whose `messages` array is the
    cumulative history up to and including that turn. This shape is what
    replay.py expects (each line = one /v1/chat/completions call).

    We emit only the user-turn-boundary requests (plus the planting turn)
    so the file isn't quadratic in size; the planting line is line 1 and
    the recall line is the last. Intermediate turns are written as
    cumulative bodies on user-message boundaries so a replay can observe
    compaction triggering as the session grows.
    """
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    user_turn_indices = [i for i, m in enumerate(messages) if m["role"] == "user"]
    count = 0
    with open(out_path, "w", encoding="utf-8") as f:
        for end_idx in user_turn_indices:
            body = {
                "model": MODEL,
                "messages": messages[: end_idx + 1],
                "temperature": 0.0,
                "stream": False,
            }
            f.write(json.dumps(body, ensure_ascii=False) + "\n")
            count += 1
    return count


def cmd_generate(args: argparse.Namespace) -> int:
    rng = random.Random(SEED)
    messages = _build_messages(rng)
    n = _emit_jsonl(messages, args.out)
    print(f"wrote {args.out} ({n} request bodies, {len(messages)} total messages)")
    print(f"needle: project_id={PROJECT_ID} secret_token={SECRET_TOKEN}")
    return 0


# Verify mode -----------------------------------------------------------------

PROJECT_ID_RE = re.compile(re.escape(PROJECT_ID))
SECRET_TOKEN_RE = re.compile(re.escape(SECRET_TOKEN))


def _grade_one(text: str) -> dict[str, Any]:
    found_pid = bool(PROJECT_ID_RE.search(text))
    found_tok = bool(SECRET_TOKEN_RE.search(text))
    return {
        "project_id_recall": found_pid,
        "secret_token_recall": found_tok,
        "pass": found_pid and found_tok,
    }


def cmd_verify(args: argparse.Namespace) -> int:
    if not os.path.exists(args.responses):
        print(f"responses not found: {args.responses}", file=sys.stderr)
        return 2
    with open(args.responses, "r", encoding="utf-8") as f:
        data = json.load(f)

    # Accept several shapes:
    #   "string"
    #   {"content": "..."}
    #   {"choices": [{"message": {"content": "..."}}]}  (raw chat-completion)
    #   [<any of the above>, ...]
    items = data if isinstance(data, list) else [data]
    results = []
    for i, item in enumerate(items):
        if isinstance(item, str):
            text = item
        elif isinstance(item, dict):
            if "choices" in item:
                try:
                    text = item["choices"][0]["message"]["content"] or ""
                except (KeyError, IndexError, TypeError):
                    text = ""
            else:
                text = item.get("content") or item.get("text") or ""
        else:
            text = ""
        graded = _grade_one(text)
        graded["index"] = i
        graded["chars"] = len(text)
        results.append(graded)

    passed = sum(1 for r in results if r["pass"])
    print(json.dumps(results, indent=2))
    print(f"\n{passed}/{len(results)} responses recalled both needles.")
    return 0 if passed == len(results) else 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Needle-in-a-haystack fixture builder and grader.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("generate", help="Write the synthetic 50-turn JSONL.")
    g.add_argument("--out", default="fixtures/needle_50turns.jsonl")
    g.set_defaults(func=cmd_generate)

    v = sub.add_parser("verify", help="Grade model responses to turn 50.")
    v.add_argument("--responses", required=True,
                   help="JSON file with the model's reply(s) to the recall turn.")
    v.set_defaults(func=cmd_verify)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
