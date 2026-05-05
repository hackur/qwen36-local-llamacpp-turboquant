#!/usr/bin/env python3
"""Tests for compact.py.

Run with pytest if available:
    pytest proxy/python/test_compact.py
or as a plain script:
    python3 proxy/python/test_compact.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
COMPACT = HERE / "compact.py"


def _run(payload: dict, *, env_extra: dict | None = None) -> tuple[int, str, str]:
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)
    proc = subprocess.run(
        [sys.executable, str(COMPACT)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env=env,
        timeout=60,
    )
    return proc.returncode, proc.stdout, proc.stderr


class TestCompact(unittest.TestCase):
    def test_pure_prose(self):
        # A few sentences of prose; sumy should produce a non-empty extract
        # within the budget. Determinism: run twice and compare.
        prose = (
            "We decided to use llama.cpp with TurboQuant on the M3 Max. "
            "The primary model is Qwen 3.6 35B-A3B at 128K context. "
            "Compaction belongs in a thin proxy in front of llama-server. "
            "The harness keeps speaking vanilla OpenAI Chat Completions. "
            "A second small summarizer model runs on a separate port. "
            "Tool-result elision is the cheapest first win. "
            "Extractive summarization with sumy is the Tier-4 fallback."
        )
        payload = {
            "messages": [
                {"role": "user", "content": "Plan our compaction strategy."},
                {"role": "assistant", "content": prose},
            ],
            "previous_summary": "",
            "token_budget": 200,
            "algorithm": "lexrank",
        }
        code, out, err = _run(payload)
        self.assertEqual(code, 0, msg=err)
        self.assertTrue(out.strip(), "summary should be non-empty")
        # Determinism check.
        code2, out2, _ = _run(payload)
        self.assertEqual(code2, 0)
        self.assertEqual(out, out2)
        # Budget check (with slack — heuristic estimator, not exact).
        approx_tokens = len(out) // 4
        self.assertLessEqual(approx_tokens, 250)

    def test_tool_results_are_dropped(self):
        # The tool-result content includes a unique JSON token. The user
        # prose includes a different unique sentence. The summary must not
        # contain the JSON marker.
        tool_payload = (
            '{"path": "/etc/secrets.json", "MARKER_DROP_ME": "leak-12345", '
            '"size": 4096, "lines": ["line1", "line2", "line3"]}'
        )
        prose_marker = "The architectural decision MARKER_KEEP_ME is the canonical record."
        msgs = [
            {"role": "user", "content": "Read the config."},
            {
                "role": "assistant",
                "content": (
                    f"I read the file. Result: <tool_result id=\"t1\">{tool_payload}</tool_result>. "
                    f"{prose_marker} "
                    "We then proceeded with the next phase of the plan and it worked well."
                ),
            },
            {"role": "tool", "content": tool_payload},
        ]
        payload = {
            "messages": msgs,
            "previous_summary": "",
            "token_budget": 300,
            "algorithm": "lexrank",
        }
        code, out, err = _run(payload)
        self.assertEqual(code, 0, msg=err)
        self.assertNotIn("MARKER_DROP_ME", out)
        self.assertNotIn("leak-12345", out)
        self.assertNotIn("/etc/secrets.json", out)

    def test_previous_summary_is_verbatim(self):
        prev = "PRIOR SUMMARY: project=proj-7B3Q-9, decided to use TurboQuant."
        payload = {
            "messages": [
                {
                    "role": "assistant",
                    "content": (
                        "We then ran the benchmarks on the M3 Max. "
                        "The results showed acceptable prefill latency."
                    ),
                }
            ],
            "previous_summary": prev,
            "token_budget": 400,
            "algorithm": "lexrank",
        }
        code, out, err = _run(payload)
        self.assertEqual(code, 0, msg=err)
        self.assertTrue(out.startswith(prev))

    def test_failure_path_returns_exit_2(self):
        # Malformed JSON on stdin → exit 2, empty stdout.
        proc = subprocess.run(
            [sys.executable, str(COMPACT)],
            input="this is not json {{{",
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(proc.returncode, 2)
        self.assertEqual(proc.stdout, "")
        self.assertTrue(proc.stderr.strip(), "should log to stderr")

    def test_empty_messages_succeeds_empty(self):
        payload = {
            "messages": [],
            "previous_summary": "",
            "token_budget": 100,
            "algorithm": "lexrank",
        }
        code, out, err = _run(payload)
        self.assertEqual(code, 0, msg=err)
        self.assertEqual(out, "")


if __name__ == "__main__":
    unittest.main()
