"""Unit + e2e tests for scripts/demo-chat.py.

Run: python3 -m unittest discover -s tests -v

The tests are stdlib-only and do not require a llama-server. The e2e
test (TestE2EFakeServer) spins up an http.server in-process and serves
canned SSE bytes that mirror the live server's output shape (see the
SPEC at the top of demo-chat.py).
"""
from __future__ import annotations

import io
import json
import os
import signal
import socket
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

# Make scripts/ importable.
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts"))

# import as a module via importlib because the file uses a hyphen.
import importlib.util
_spec = importlib.util.spec_from_file_location(
    "demo_chat",
    os.path.join(HERE, "..", "scripts", "demo-chat.py"),
)
demo_chat = importlib.util.module_from_spec(_spec)
sys.modules["demo_chat"] = demo_chat  # required for dataclass __module__ lookup on 3.14+
_spec.loader.exec_module(demo_chat)


# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------


class TestSanitizer(unittest.TestCase):
    def test_strips_c0_except_whitespace(self):
        s = "hello\x00\x07\x1bworld\n\tx\r"
        self.assertEqual(demo_chat.sanitize_chunk(s), "helloworld\n\tx\r")

    def test_passes_unicode(self):
        self.assertEqual(demo_chat.sanitize_chunk("café 🤖 наука"), "café 🤖 наука")

    def test_empty(self):
        self.assertEqual(demo_chat.sanitize_chunk(""), "")


class TestSSEParser(unittest.TestCase):
    def _drive(self, raw: bytes, chunk_size: int = 7):
        # Yield in small chunks to exercise mid-line boundaries.
        def gen():
            for i in range(0, len(raw), chunk_size):
                yield raw[i:i + chunk_size]
        return list(demo_chat.parse_sse_stream(gen()))

    def test_done_terminates(self):
        evs = self._drive(b"data: [DONE]\n\n")
        self.assertEqual([e.kind for e in evs], ["done"])

    def test_empty_stream(self):
        self.assertEqual(self._drive(b""), [])

    def test_content_and_reasoning_split(self):
        # Mirrors the live server probe.
        chunks = (
            b'data: {"choices":[{"delta":{"reasoning_content":"Hmm"}}]}\n\n'
            b'data: {"choices":[{"delta":{"reasoning_content":"."}}]}\n\n'
            b'data: {"choices":[{"delta":{"content":"4"}}]}\n\n'
            b'data: [DONE]\n\n'
        )
        evs = self._drive(chunks)
        kinds = [e.kind for e in evs]
        self.assertEqual(kinds, ["reasoning", "reasoning", "content", "done"])
        self.assertEqual(evs[0].text, "Hmm")
        self.assertEqual(evs[1].text, ".")
        self.assertEqual(evs[2].text, "4")

    def test_finish_then_usage(self):
        chunks = (
            b'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
            b'data: {"choices":[],"usage":{"completion_tokens":3},"timings":{"predicted_per_second":12.5,"predicted_n":3,"predicted_ms":240.0}}\n\n'
            b'data: [DONE]\n\n'
        )
        evs = self._drive(chunks)
        kinds = [e.kind for e in evs]
        self.assertEqual(kinds, ["finish", "usage", "done"])
        self.assertEqual(evs[0].finish_reason, "stop")
        self.assertEqual(evs[1].timings["predicted_per_second"], 12.5)

    def test_malformed_line_is_skipped(self):
        chunks = (
            b'data: not-json\n\n'
            b'data: {"choices":[{"delta":{"content":"ok"}}]}\n\n'
            b'data: [DONE]\n\n'
        )
        evs = self._drive(chunks)
        self.assertEqual([e.kind for e in evs], ["content", "done"])

    def test_byte_boundary_in_middle_of_event(self):
        # Same payload, but tiny chunks → must not lose bytes.
        chunks = b'data: {"choices":[{"delta":{"content":"abc"}}]}\n\ndata: [DONE]\n\n'
        evs = self._drive(chunks, chunk_size=1)
        self.assertEqual([e.kind for e in evs], ["content", "done"])
        self.assertEqual(evs[0].text, "abc")


# ---------------------------------------------------------------------------
# History
# ---------------------------------------------------------------------------


class TestHistory(unittest.TestCase):
    def test_append_and_to_messages(self):
        h = demo_chat.History()
        h.append("user", "hi")
        h.append("assistant", "hello", reasoning="quick check")
        msgs = h.to_messages()
        self.assertEqual(msgs, [
            {"role": "user", "content": "hi"},
            {"role": "assistant", "content": "hello"},
        ])

    def test_reset_keeps_system(self):
        h = demo_chat.History(system="be terse")
        h.append("user", "hi")
        h.append("assistant", "hi")
        h.reset()
        self.assertEqual(len(h.messages), 1)
        self.assertEqual(h.messages[0].role, "system")

    def test_reset_without_system(self):
        h = demo_chat.History()
        h.append("user", "x")
        h.reset()
        self.assertEqual(h.messages, [])

    def test_prune_drops_oldest_pairs_keeps_system(self):
        h = demo_chat.History(system="sys")
        for i in range(5):
            h.append("user", "u" * 100)
            h.append("assistant", "a" * 100)
        before = len(h.messages)
        dropped = h.prune_to_chars(400)
        self.assertGreater(dropped, 0)
        self.assertEqual(h.messages[0].role, "system")
        self.assertLessEqual(h.char_total(), 400 + 200)  # last pair may push us over
        self.assertLess(len(h.messages), before)

    def test_save_load_roundtrip(self):
        h = demo_chat.History(system="sys")
        h.append("user", "hi")
        h.append("assistant", "hello", reasoning="thought")
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            path = f.name
        try:
            h.save(path)
            h2 = demo_chat.History()
            h2.load(path)
            self.assertEqual(len(h2.messages), 3)
            self.assertEqual(h2.messages[2].reasoning, "thought")
        finally:
            os.unlink(path)


# ---------------------------------------------------------------------------
# Slash commands
# ---------------------------------------------------------------------------


class TestSlashDispatch(unittest.TestCase):
    def _state(self):
        return demo_chat.State(
            history=demo_chat.History(),
            think="off",
            port=10501,
            max_history_chars=10_000,
        )

    def test_unknown_returns_unhandled(self):
        s = self._state()
        handled, quit_now = demo_chat.dispatch_slash("hello world", s)
        self.assertFalse(handled)
        self.assertFalse(quit_now)

    def test_unknown_slash_passes_through(self):
        s = self._state()
        handled, quit_now = demo_chat.dispatch_slash("/notacommand", s)
        self.assertFalse(handled)

    def test_quit(self):
        s = self._state()
        handled, quit_now = demo_chat.dispatch_slash("/quit", s)
        self.assertTrue(handled)
        self.assertTrue(quit_now)

    def test_reset_clears(self):
        s = self._state()
        s.history.append("user", "hi")
        demo_chat.dispatch_slash("/reset", s)
        self.assertEqual(s.history.messages, [])

    def test_think_toggle(self):
        s = self._state()
        self.assertEqual(s.think, "off")
        demo_chat.dispatch_slash("/think toggle", s)
        self.assertEqual(s.think, "on")
        demo_chat.dispatch_slash("/think toggle", s)
        self.assertEqual(s.think, "off")

    def test_think_set(self):
        s = self._state()
        demo_chat.dispatch_slash("/think auto", s)
        self.assertEqual(s.think, "auto")

    def test_save_load(self):
        s = self._state()
        s.history.append("user", "hi")
        s.history.append("assistant", "yo", reasoning="r")
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            path = f.name
        try:
            demo_chat.dispatch_slash(f"/save {path}", s)
            s.history.reset()
            self.assertEqual(s.history.messages, [])
            demo_chat.dispatch_slash(f"/load {path}", s)
            self.assertEqual(len(s.history.messages), 2)
            self.assertEqual(s.history.messages[1].reasoning, "r")
        finally:
            os.unlink(path)


# ---------------------------------------------------------------------------
# Renderer (capture stdout)
# ---------------------------------------------------------------------------


class TestRenderer(unittest.TestCase):
    def setUp(self):
        self.buf = io.StringIO()
        self.r = demo_chat.Renderer(out=self.buf)

    def test_content_only(self):
        self.r.start_turn()
        self.r.on_content("hello")
        self.r.on_content(" world")
        self.r.end_turn(None)
        out = self.buf.getvalue()
        self.assertIn("qwen> ", out)
        self.assertIn("hello world", out)

    def test_reasoning_then_content_separator(self):
        self.r.start_turn()
        self.r.on_reasoning("thinking...")
        self.r.on_content("answer")
        self.r.end_turn(None)
        out = self.buf.getvalue()
        self.assertIn("[thinking] ", out)
        self.assertIn("thinking...", out)
        # Blank line separator between reasoning and content.
        self.assertIn("\n\nanswer", out)

    def test_thinking_prefix_appears_only_once(self):
        self.r.start_turn()
        self.r.on_reasoning("a")
        self.r.on_reasoning("b")
        self.r.on_reasoning("c")
        self.r.end_turn(None)
        out = self.buf.getvalue()
        self.assertEqual(out.count("[thinking] "), 1)

    def test_chunks_sanitized(self):
        self.r.start_turn()
        self.r.on_content("safe\x07\x1bsafe")
        self.r.end_turn(None)
        out = self.buf.getvalue()
        self.assertNotIn("\x07", out)
        self.assertNotIn("\x1b[A", out)  # no random escape, only our color tags

    def test_timings_line(self):
        self.r.start_turn()
        self.r.on_content("hi")
        self.r.end_turn({"predicted_per_second": 14.2, "predicted_n": 50, "predicted_ms": 3520.0})
        out = self.buf.getvalue()
        self.assertIn("50 tok", out)
        self.assertIn("14.2 tok/s", out)


# ---------------------------------------------------------------------------
# E2E: fake llama-server
# ---------------------------------------------------------------------------


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class _FakeHandler(BaseHTTPRequestHandler):
    # Class attr — set by test
    canned_sse: bytes = b""

    def log_message(self, *a, **kw):
        pass  # silence

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
            return
        self.send_error(404)

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404); return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(self.canned_sse)))
        self.end_headers()
        # Send the whole canned blob at once. The parser's tolerance to
        # arbitrary chunk boundaries is exercised separately in
        # TestSSEParser.test_byte_boundary_in_middle_of_event.
        self.wfile.write(self.canned_sse)
        self.wfile.flush()


class _FakeServer:
    def __init__(self, sse: bytes):
        _FakeHandler.canned_sse = sse
        self.port = _free_port()
        self.httpd = HTTPServer(("127.0.0.1", self.port), _FakeHandler)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    def __enter__(self):
        self.thread.start()
        # Tiny wait for socket-ready.
        for _ in range(20):
            if demo_chat.health_check(self.port):
                break
            time.sleep(0.05)
        return self

    def __exit__(self, *a):
        self.httpd.shutdown()
        self.httpd.server_close()


_CANNED_THINK_OFF = (
    b'data: {"choices":[{"delta":{"role":"assistant","content":""}}]}\n\n'
    b'data: {"choices":[{"delta":{"content":"- apple\\n"}}]}\n\n'
    b'data: {"choices":[{"delta":{"content":"- pear\\n"}}]}\n\n'
    b'data: {"choices":[{"delta":{"content":"- mango"}}]}\n\n'
    b'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
    b'data: {"choices":[],"usage":{"completion_tokens":3},"timings":{"predicted_per_second":42.0,"predicted_n":12,"predicted_ms":285.7}}\n\n'
    b'data: [DONE]\n\n'
)

_CANNED_THINK_ON = (
    b'data: {"choices":[{"delta":{"reasoning_content":"User wants 2+2."}}]}\n\n'
    b'data: {"choices":[{"delta":{"reasoning_content":" That is 4."}}]}\n\n'
    b'data: {"choices":[{"delta":{"content":"4"}}]}\n\n'
    b'data: {"choices":[],"timings":{"predicted_per_second":15.0,"predicted_n":1,"predicted_ms":66.6}}\n\n'
    b'data: [DONE]\n\n'
)


class TestE2EFakeServer(unittest.TestCase):
    def _run_turn(self, sse: bytes, think: str = "off"):
        with _FakeServer(sse) as srv:
            buf = io.StringIO()
            renderer = demo_chat.Renderer(out=buf)
            state = demo_chat.State(
                history=demo_chat.History(),
                think=think,
                port=srv.port,
                max_history_chars=10_000,
            )
            demo_chat.run_turn(state, "list 3 fruits", renderer)
            return state, buf.getvalue()

    def test_clean_markdown_list_render(self):
        state, out = self._run_turn(_CANNED_THINK_OFF)
        # Bullets must be on separate lines (the original bug was list collapse).
        self.assertIn("- apple\n", out)
        self.assertIn("- pear\n", out)
        self.assertIn("- mango", out)
        # Timings line shown.
        self.assertIn("12 tok", out)
        # History has the full assistant content concatenated.
        self.assertEqual(state.history.messages[-1].role, "assistant")
        self.assertEqual(state.history.messages[-1].content, "- apple\n- pear\n- mango")

    def test_thinking_stream_and_history(self):
        state, out = self._run_turn(_CANNED_THINK_ON, think="on")
        self.assertIn("[thinking] ", out)
        self.assertIn("That is 4.", out)
        # Reasoning preserved on the assistant message.
        a = state.history.messages[-1]
        self.assertEqual(a.content, "4")
        self.assertIn("That is 4.", a.reasoning)

    def test_whitespace_input_no_request(self):
        # Drive main() with stdin containing only whitespace lines + EOF.
        # No request should reach the server (would hang otherwise — empty
        # canned bytes would yield no events, and run_turn would block on
        # urllib.read; instead we never call run_turn at all).
        canned = b'data: [DONE]\n\n'  # served if anything sneaks through
        with _FakeServer(canned) as srv:
            old_stdin = sys.stdin
            sys.stdin = io.StringIO("   \n\t\n  \t  \n")  # then EOF
            try:
                rc = demo_chat.main(["--port", str(srv.port)])
            finally:
                sys.stdin = old_stdin
            self.assertEqual(rc, 0)

    def test_health_check_failure(self):
        # No server up on a random port → main() returns 1.
        port = _free_port()
        rc = demo_chat.main(["--port", str(port)])
        self.assertEqual(rc, 1)


# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------


class TestCLIParsing(unittest.TestCase):
    def test_defaults(self):
        # Ensure no env var pollution.
        env_port = os.environ.pop("PORT", None)
        env_think = os.environ.pop("THINK", None)
        try:
            ns = demo_chat.parse_args([])
            self.assertEqual(ns.port, 10501)
            self.assertEqual(ns.think, "off")
        finally:
            if env_port is not None: os.environ["PORT"] = env_port
            if env_think is not None: os.environ["THINK"] = env_think

    def test_env_think_one_maps_on(self):
        os.environ["THINK"] = "1"
        try:
            ns = demo_chat.parse_args([])
            self.assertEqual(ns.think, "on")
        finally:
            del os.environ["THINK"]

    def test_flag_overrides_env(self):
        os.environ["THINK"] = "1"
        try:
            ns = demo_chat.parse_args(["--think", "off"])
            self.assertEqual(ns.think, "off")
        finally:
            del os.environ["THINK"]


if __name__ == "__main__":
    unittest.main(verbosity=2)
