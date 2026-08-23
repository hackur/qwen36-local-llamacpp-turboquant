#!/usr/bin/env python3
"""
Offline streaming chat REPL for the local llama-server (TurboQuant build).

SPEC (behavior contract enforced by tests/test_demo_chat.py)
-----------------------------------------------------------

I/O
  - Reads lines from stdin via input(), prints to stdout with ANSI colors.
  - Whitespace-only input is ignored (no HTTP request made, prompt redrawn).
  - EOF (Ctrl-D) at empty prompt exits cleanly with code 0.

Streaming protocol
  - POSTs to {url}/v1/chat/completions with stream=true and
    stream_options.include_usage=true so the final SSE event carries
    the server's usage + (llama.cpp) timings block.
  - Parses Server-Sent Events: lines starting with "data: ", terminated
    by an event boundary (blank line). The literal payload "[DONE]"
    ends the stream.
  - Each delta may carry EITHER `content` OR `reasoning_content`
    (this server splits them when --jinja is on and the chat template
    supports thinking). The parser surfaces both as separate events.

Thinking
  - Tri-state: "on" / "off" / "auto" (let server default decide).
  - Reasoning content streams dimmed and prefixed `[thinking] ` once;
    when content arrives, a blank line separates it and the dim-color
    is closed. This makes the (previously invisible) thinking output
    visible AND visually distinct from the final answer.
  - The original bash REPL only read delta.content and silently
    discarded delta.reasoning_content — that's why thinking turns
    appeared as a long pause followed by garbled output.

Slash commands
  /help                — print available commands
  /reset               — clear conversation history
  /think on|off|toggle — change thinking mode for subsequent turns
  /save PATH           — write history (incl. reasoning) to PATH as JSON
  /load PATH           — replace history with contents of PATH
  /history             — print message count and rough char total
  /quit                — exit cleanly (also Ctrl-D)
  Unknown slash input  — sent to the model verbatim.

Robustness
  - Streamed chunks are sanitized: C0 control bytes (0x00–0x1F) are
    stripped except for \\n, \\t, \\r. Prevents stray escape sequences
    from corrupting the user's terminal — that was the cause of the
    "wall of trailing prompts" bug in the bash version.
  - SIGINT during a stream cancels the in-flight reply, prints
    "(interrupted)", saves the partial reply to history, and returns
    to the prompt — does not exit.
  - Connection errors print to stderr in red and return to the prompt
    without losing history.

History
  - In-memory list of {role, content, reasoning?}.
  - prune_to_chars() drops oldest non-system pairs when the rough
    total exceeds --max-history-chars (default 200_000 ≈ 50K tokens).
  - to_messages() omits `reasoning` when serializing for the API
    (the server replays based on content only).

Env-var compatibility (matches the prior bash REPL)
  PORT  → default for --port      (default 10501)
  THINK → "1" maps to --think on; otherwise --think off
  Flags override env.

Exit codes
  0 — clean exit
  1 — could not reach server on startup
  2 — protocol error (malformed SSE we couldn't recover from)
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import re
import signal
import sys
import time
import urllib.error
import urllib.request
from typing import Callable, Iterable, Iterator, List, Optional, Tuple


# ---------------------------------------------------------------------------
# ANSI helpers
# ---------------------------------------------------------------------------

CYAN = "\x1b[36m"
GREEN = "\x1b[32m"
DIM = "\x1b[2m"
RED = "\x1b[31m"
RESET = "\x1b[0m"


def _isatty() -> bool:
    return sys.stdout.isatty()


def _color(s: str, code: str) -> str:
    return f"{code}{s}{RESET}" if _isatty() else s


# ---------------------------------------------------------------------------
# Pure helpers (sanitizer, SSE parser)
# ---------------------------------------------------------------------------

# Allow \t (0x09), \n (0x0A), \r (0x0D); strip the rest of C0.
_C0_STRIP = re.compile(r"[\x00-\x08\x0B\x0C\x0E-\x1F]")


def sanitize_chunk(s: str) -> str:
    """Drop C0 control bytes except \\t, \\n, \\r. Pass through everything else."""
    return _C0_STRIP.sub("", s)


@dataclasses.dataclass
class SSEEvent:
    """Normalised event yielded by parse_sse_stream."""
    kind: str  # "content" | "reasoning" | "finish" | "usage" | "done"
    text: str = ""
    finish_reason: Optional[str] = None
    usage: Optional[dict] = None
    timings: Optional[dict] = None


def parse_sse_stream(byte_iter: Iterable[bytes]) -> Iterator[SSEEvent]:
    """Parse an SSE byte stream into SSEEvents.

    The parser is pure: it consumes any iterable of bytes (network chunks,
    test fixtures, files) and yields events. It tolerates byte boundaries
    falling mid-line and mid-event, which the bash version did not.
    """
    buf = b""
    for chunk in byte_iter:
        if not chunk:
            continue
        buf += chunk
        # Process complete lines; keep the trailing partial line in buf.
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            line = line.rstrip(b"\r")
            if not line:
                continue
            if not line.startswith(b"data:"):
                continue  # SSE comments / event: lines — ignore
            payload = line[5:].lstrip()
            if payload == b"[DONE]":
                yield SSEEvent(kind="done")
                return
            try:
                obj = json.loads(payload.decode("utf-8", errors="replace"))
            except json.JSONDecodeError:
                # Skip malformed line; do not abort the stream.
                continue
            yield from _events_from_json(obj)
    # Any trailing partial line is discarded (no terminating newline).


def _events_from_json(obj: dict) -> Iterator[SSEEvent]:
    """Translate one parsed SSE JSON payload into zero or more SSEEvents."""
    choices = obj.get("choices") or []
    if choices:
        c0 = choices[0]
        delta = c0.get("delta") or {}
        rc = delta.get("reasoning_content")
        if isinstance(rc, str) and rc:
            yield SSEEvent(kind="reasoning", text=rc)
        ct = delta.get("content")
        if isinstance(ct, str) and ct:
            yield SSEEvent(kind="content", text=ct)
        fr = c0.get("finish_reason")
        if fr:
            yield SSEEvent(kind="finish", finish_reason=fr)
    # llama.cpp emits a final chunk with empty `choices` and a `usage` block.
    if "usage" in obj or "timings" in obj:
        yield SSEEvent(kind="usage", usage=obj.get("usage"), timings=obj.get("timings"))


# ---------------------------------------------------------------------------
# History
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class Message:
    role: str
    content: str
    reasoning: str = ""

    def to_api(self) -> dict:
        """Form sent to the server. Reasoning is local-only state."""
        return {"role": self.role, "content": self.content}


class History:
    """Conversation history. System message (if present) is always preserved."""

    def __init__(self, system: Optional[str] = None) -> None:
        self.messages: List[Message] = []
        if system:
            self.messages.append(Message("system", system))

    def append(self, role: str, content: str, reasoning: str = "") -> None:
        self.messages.append(Message(role, content, reasoning))

    def reset(self) -> None:
        # Keep only the leading system message (if any).
        if self.messages and self.messages[0].role == "system":
            self.messages = [self.messages[0]]
        else:
            self.messages = []

    def char_total(self) -> int:
        return sum(len(m.content) + len(m.reasoning) for m in self.messages)

    def prune_to_chars(self, limit: int) -> int:
        """Drop oldest non-system message PAIRS until under `limit`. Returns count dropped."""
        dropped = 0
        # Index of first non-system message
        start = 1 if self.messages and self.messages[0].role == "system" else 0
        while self.char_total() > limit and len(self.messages) - start >= 2:
            # Drop the oldest user+assistant pair.
            del self.messages[start:start + 2]
            dropped += 2
        return dropped

    def to_messages(self) -> List[dict]:
        return [m.to_api() for m in self.messages]

    def save(self, path: str) -> None:
        data = [dataclasses.asdict(m) for m in self.messages]
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)

    def load(self, path: str) -> None:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        self.messages = [Message(**d) for d in data]


# ---------------------------------------------------------------------------
# Renderer
# ---------------------------------------------------------------------------


class Renderer:
    """Stateful streaming printer. One instance per turn."""

    def __init__(self, out=sys.stdout) -> None:
        self.out = out
        self._mode: Optional[str] = None  # "reasoning" | "content"

    def _write(self, s: str) -> None:
        self.out.write(s)
        self.out.flush()

    def start_turn(self) -> None:
        self._mode = None
        self._write(_color("qwen> ", GREEN))

    def on_reasoning(self, s: str) -> None:
        s = sanitize_chunk(s)
        if not s:
            return
        if self._mode != "reasoning":
            self._mode = "reasoning"
            if _isatty():
                self._write(DIM + "[thinking] ")
            else:
                self._write("[thinking] ")
        self._write(s)

    def on_content(self, s: str) -> None:
        s = sanitize_chunk(s)
        if not s:
            return
        if self._mode == "reasoning":
            if _isatty():
                self._write(RESET)
            self._write("\n\n")
        self._mode = "content"
        self._write(s)

    def end_turn(self, timings: Optional[dict]) -> None:
        if self._mode == "reasoning" and _isatty():
            self._write(RESET)
        self._write("\n")
        if timings:
            t = timings.get("predicted_per_second") or 0
            n = timings.get("predicted_n") or 0
            ms = timings.get("predicted_ms") or 0
            self._write(_color(f"  · {n} tok / {ms / 1000:.1f}s / {t:.1f} tok/s\n", DIM))


# ---------------------------------------------------------------------------
# HTTP streaming client
# ---------------------------------------------------------------------------


class StreamCancelled(Exception):
    pass


class StreamConnection:
    """Wraps an in-flight urllib response so it can be cancelled by the REPL."""

    def __init__(self, url: str, body: dict, timeout: float = 600.0) -> None:
        self.url = url
        self.body = body
        self.timeout = timeout
        self._resp = None

    def open(self) -> None:
        data = json.dumps(self.body).encode("utf-8")
        req = urllib.request.Request(
            self.url, data=data, headers={"Content-Type": "application/json"}
        )
        self._resp = urllib.request.urlopen(req, timeout=self.timeout)

    def close(self) -> None:
        if self._resp is not None:
            try:
                self._resp.close()
            except Exception:
                pass
            self._resp = None

    def iter_bytes(self, chunk_size: int = 1024) -> Iterator[bytes]:
        assert self._resp is not None, "open() first"
        while True:
            try:
                buf = self._resp.read(chunk_size)
            except (ValueError, OSError):
                # Closed mid-read by SIGINT handler → treat as cancellation.
                raise StreamCancelled()
            if not buf:
                return
            yield buf


# ---------------------------------------------------------------------------
# Slash-command dispatcher
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class State:
    history: History
    think: str  # "on" | "off" | "auto"
    port: int
    max_history_chars: int


def dispatch_slash(line: str, state: State) -> Tuple[bool, bool]:
    """Returns (handled, should_quit). `handled=False` means the line is not
    a slash command and should be sent to the model."""
    if not line.startswith("/"):
        return False, False
    parts = line.strip().split(maxsplit=1)
    cmd = parts[0]
    arg = parts[1] if len(parts) > 1 else ""

    if cmd in ("/quit", "/exit"):
        return True, True
    if cmd == "/help":
        print(_HELP_TEXT)
        return True, False
    if cmd == "/reset":
        state.history.reset()
        print(_color("(history cleared)", DIM))
        return True, False
    if cmd == "/think":
        a = arg.strip().lower()
        if a == "toggle":
            state.think = "off" if state.think == "on" else "on"
        elif a in ("on", "off", "auto"):
            state.think = a
        else:
            print(_color(f"  current: --think {state.think}. usage: /think on|off|toggle", DIM))
            return True, False
        print(_color(f"(thinking → {state.think})", DIM))
        return True, False
    if cmd == "/save":
        if not arg:
            print(_color("usage: /save PATH", DIM)); return True, False
        try:
            state.history.save(arg)
            print(_color(f"(saved {len(state.history.messages)} messages → {arg})", DIM))
        except OSError as e:
            print(_color(f"(save failed: {e})", RED), file=sys.stderr)
        return True, False
    if cmd == "/load":
        if not arg:
            print(_color("usage: /load PATH", DIM)); return True, False
        try:
            state.history.load(arg)
            print(_color(f"(loaded {len(state.history.messages)} messages from {arg})", DIM))
        except (OSError, json.JSONDecodeError) as e:
            print(_color(f"(load failed: {e})", RED), file=sys.stderr)
        return True, False
    if cmd == "/history":
        print(_color(
            f"  {len(state.history.messages)} messages, "
            f"~{state.history.char_total()} chars (limit {state.max_history_chars})",
            DIM,
        ))
        return True, False
    # Unknown /something — let it fall through to the model.
    return False, False


_HELP_TEXT = """\
  /help                  — this message
  /reset                 — clear history
  /think on|off|toggle   — change thinking mode
  /save PATH             — write history JSON
  /load PATH             — read history JSON
  /history               — show message count + char total
  /quit                  — exit (also Ctrl-D)
"""


# ---------------------------------------------------------------------------
# Main REPL
# ---------------------------------------------------------------------------


def build_request_body(state: State, history: History) -> dict:
    body: dict = {
        "model": "qwen3.8-local",
        "stream": True,
        "stream_options": {"include_usage": True},
        "messages": history.to_messages(),
        "max_tokens": 1024,
    }
    if state.think in ("on", "off"):
        body["chat_template_kwargs"] = {"enable_thinking": state.think == "on"}
    return body


def run_turn(state: State, user_text: str, renderer: Renderer) -> None:
    state.history.append("user", user_text)
    state.history.prune_to_chars(state.max_history_chars)
    body = build_request_body(state, state.history)
    url = f"http://127.0.0.1:{state.port}/v1/chat/completions"

    conn = StreamConnection(url, body)
    reasoning_acc: List[str] = []
    content_acc: List[str] = []
    timings: Optional[dict] = None

    def cancel_handler(signum, frame):
        conn.close()  # iter_bytes will raise StreamCancelled
    prev_handler = signal.signal(signal.SIGINT, cancel_handler)

    renderer.start_turn()
    try:
        try:
            conn.open()
        except urllib.error.URLError as e:
            print(_color(f"\n  (server unreachable: {e})", RED), file=sys.stderr)
            return

        try:
            for ev in parse_sse_stream(conn.iter_bytes()):
                if ev.kind == "reasoning":
                    reasoning_acc.append(ev.text)
                    renderer.on_reasoning(ev.text)
                elif ev.kind == "content":
                    content_acc.append(ev.text)
                    renderer.on_content(ev.text)
                elif ev.kind == "usage":
                    timings = ev.timings
                elif ev.kind in ("finish", "done"):
                    pass  # advisory — keep reading until the stream closes
        except StreamCancelled:
            print(_color("\n  (interrupted)", DIM))
    finally:
        signal.signal(signal.SIGINT, prev_handler)
        conn.close()

    renderer.end_turn(timings)
    state.history.append(
        "assistant",
        "".join(content_acc),
        reasoning="".join(reasoning_acc),
    )


def repl(state: State) -> int:
    print(f"Connected to :{state.port}  ·  /help for commands  ·  Ctrl-D to quit")
    print(f"thinking={state.think}  history-cap={state.max_history_chars} chars")
    while True:
        try:
            line = input(_color("you> ", CYAN))
        except EOFError:
            print()
            return 0
        except KeyboardInterrupt:
            # Ctrl-C at the prompt: clear current line, redraw prompt.
            print()
            continue

        if not line.strip():
            continue

        handled, quit_now = dispatch_slash(line, state)
        if quit_now:
            return 0
        if handled:
            continue

        try:
            run_turn(state, line, Renderer())
        except KeyboardInterrupt:
            # Belt-and-suspenders: if SIGINT slips past the per-turn handler.
            print(_color("\n  (interrupted)", DIM))


def health_check(port: int) -> bool:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as r:
            return r.status == 200
    except (urllib.error.URLError, OSError):
        return False


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_args(argv: List[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(
        prog="demo-chat",
        description="Offline streaming chat REPL for the local llama-server.",
    )
    p.add_argument("--port", type=int,
                   default=int(os.environ.get("PORT", "10501")),
                   help="llama-server port (env: PORT, default 10501)")
    p.add_argument("--think",
                   choices=["on", "off", "auto"],
                   default=("on" if os.environ.get("THINK") == "1" else "off"),
                   help="thinking mode (env: THINK=1 → on; default off)")
    p.add_argument("--max-history-chars", type=int, default=200_000,
                   help="rough cap on history size before oldest pairs are dropped")
    p.add_argument("--system", type=str, default=None,
                   help="optional system prompt")
    return p.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    if not health_check(args.port):
        print(
            f"no server on :{args.port} — start one with scripts/start-turboquant.sh",
            file=sys.stderr,
        )
        return 1
    state = State(
        history=History(system=args.system),
        think=args.think,
        port=args.port,
        max_history_chars=args.max_history_chars,
    )
    return repl(state)


if __name__ == "__main__":
    sys.exit(main())
