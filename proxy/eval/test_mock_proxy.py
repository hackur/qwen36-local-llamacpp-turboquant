#!/usr/bin/env python3
"""test_mock_proxy.py — local HTTP server that implements the
rewritten-request contract documented in proxy/eval/README.md.

Purpose: smoke-test replay.py end-to-end without requiring a live
llama-server or the Node proxy. The mock implements the same
short-circuit behaviour as proxy/src/server.js when
`x-debug-rewritten: 1` is set on the request:

    - Always responds 200 with body `{}`
    - Sets `x-rewrite-stats` JSON header
    - Sets `x-rewritten-messages` inline if it fits within
      INLINE_HEADER_BUDGET (6 KiB, mirroring server.js); otherwise
      writes a sidecar JSON file under cache_dir/debug/<id>.json and
      sets `x-rewritten-sidecar` to the absolute path.
    - Sets `x-proxy-request-id`.

Compaction logic is intentionally trivial: we elide every role=tool
message body (replacing with a stub `<tool_result id="..." />`) and
report the elided ids. Token counts are 4-chars-per-token estimates,
which is fine for replay smoke testing — the contract here is the
SHAPE, not the values.

Run standalone:
    python3 test_mock_proxy.py --port 11599 --cache-dir /tmp/mock-cache

Or use as a context manager from the smoke test runner:
    with run_mock_proxy(port=0, cache_dir=...) as url:
        ... # url is the bound base URL
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

INLINE_HEADER_BUDGET = 6 * 1024


def _est_tokens(s: str) -> int:
    if not s:
        return 0
    return max(1, (len(s) + 3) // 4)


def _messages_text(messages):
    parts = []
    for m in messages:
        c = m.get("content")
        if isinstance(c, str):
            parts.append(c)
        elif isinstance(c, list):
            for blk in c:
                if isinstance(blk, dict):
                    parts.append(json.dumps(blk, sort_keys=True))
    return "\n".join(parts)


def _rewrite(messages):
    """Trivial compaction: stub every role=tool message body."""
    elided = []
    out = []
    for m in messages:
        if m.get("role") == "tool":
            tcid = str(m.get("tool_call_id") or f"anon-{len(elided)}")
            elided.append(tcid)
            name = m.get("name") or "tool"
            stub = f'<tool_result id="{tcid}" tool="{name}" />'
            new = dict(m)
            new["content"] = stub
            out.append(new)
        else:
            out.append(m)
    return out, elided


class MockHandler(BaseHTTPRequestHandler):
    # Suppress the default stderr access log so smoke runs are quiet.
    def log_message(self, fmt, *args):  # noqa: A003 - inherited name
        return

    def do_POST(self):  # noqa: N802 - inherited name
        if self.path != "/v1/chat/completions":
            self.send_error(404, "not found")
            return

        length = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw.decode("utf-8")) if raw else {}
        except json.JSONDecodeError:
            self.send_error(400, "bad json")
            return

        debug = self.headers.get("x-debug-rewritten") == "1"
        messages = body.get("messages") or []

        rewritten, elided = _rewrite(messages)
        stats = {
            "orig_tokens": _est_tokens(_messages_text(messages)),
            "rewritten_tokens": _est_tokens(_messages_text(rewritten)),
            "elided_tool_result_ids": elided,
        }

        request_id = str(uuid.uuid4())
        cache_dir = self.server.cache_dir  # type: ignore[attr-defined]

        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("x-proxy-request-id", request_id)
        if debug:
            self.send_header("x-rewrite-stats", json.dumps(stats))
            inline = json.dumps(rewritten)
            if len(inline) <= INLINE_HEADER_BUDGET:
                self.send_header("x-rewritten-messages", inline)
            else:
                debug_dir = os.path.join(cache_dir, "debug")
                os.makedirs(debug_dir, exist_ok=True)
                sidecar = os.path.abspath(
                    os.path.join(debug_dir, f"{request_id}.json")
                )
                with open(sidecar, "w", encoding="utf-8") as f:
                    json.dump(rewritten, f)
                self.send_header("x-rewritten-sidecar", sidecar)
        payload = b"{}"
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


@contextlib.contextmanager
def run_mock_proxy(port: int = 0, cache_dir: str | None = None):
    cache_dir = cache_dir or "/tmp/mock-proxy-cache"
    os.makedirs(cache_dir, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", port), MockHandler)
    server.cache_dir = cache_dir  # type: ignore[attr-defined]
    bound_port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{bound_port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=11599)
    ap.add_argument("--cache-dir", default="/tmp/mock-proxy-cache")
    args = ap.parse_args(argv)

    os.makedirs(args.cache_dir, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", args.port), MockHandler)
    server.cache_dir = args.cache_dir  # type: ignore[attr-defined]
    print(f"mock proxy listening on http://127.0.0.1:{args.port}", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
