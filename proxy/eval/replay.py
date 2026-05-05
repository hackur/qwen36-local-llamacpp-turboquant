#!/usr/bin/env python3
"""replay.py — replay a session JSONL through the compaction proxy and diff
the rewritten request against the original.

This script is independent of the proxy implementation. It assumes the proxy
honors the rewritten-request contract documented in proxy/eval/README.md:

    Request:  client sets header `x-debug-rewritten: 1`.
    Response: proxy sets headers
              - `x-rewritten-messages`: JSON-encoded rewritten message array
                (the array that was actually forwarded to llama-server), OR
              - `x-rewritten-sidecar`: filesystem path to a JSON file holding
                the same array (used when the array is too large for a header).
              - `x-rewrite-stats`: JSON object with at least
                {"orig_tokens": int, "rewritten_tokens": int,
                 "elided_tool_result_ids": [str, ...]}.

The script does NOT consume the model output — it only inspects what the
proxy *would* send upstream. Run the proxy in shadow mode (§8.4) for safety.

Usage:
    python3 replay.py --target http://localhost:11500/v1/chat/completions \\
                     --session path/to/session.jsonl \\
                     [--max N] [--timeout 30] [--out report.json]

Stdlib + urllib only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field, asdict
from typing import Any


# Header contract -------------------------------------------------------------

DEBUG_REQUEST_HEADER = "x-debug-rewritten"
HEADER_REWRITTEN_INLINE = "x-rewritten-messages"
HEADER_REWRITTEN_SIDECAR = "x-rewritten-sidecar"
HEADER_STATS = "x-rewrite-stats"


# Rough token estimator (no tiktoken; deliberate, per repo constraints).
# Used only when the proxy does not return token counts. The proxy itself
# should always tokenize via llama-server's /tokenize for accurate numbers.
def _estimate_tokens(text: str) -> int:
    if not text:
        return 0
    # ~4 chars per token is a defensible default for English + code mix.
    return max(1, (len(text) + 3) // 4)


def _messages_text(messages: list[dict[str, Any]]) -> str:
    parts: list[str] = []
    for m in messages:
        content = m.get("content")
        if isinstance(content, str):
            parts.append(content)
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict):
                    parts.append(json.dumps(block, sort_keys=True))
        # tool_calls / tool_call_id etc.
        for k in ("tool_calls", "tool_call_id", "name", "role"):
            v = m.get(k)
            if v is not None:
                parts.append(json.dumps(v, sort_keys=True))
    return "\n".join(parts)


def _collect_tool_result_ids(messages: list[dict[str, Any]]) -> set[str]:
    ids: set[str] = set()
    for m in messages:
        if m.get("role") == "tool":
            tcid = m.get("tool_call_id")
            if tcid:
                ids.add(str(tcid))
        # Some agents nest tool_result blocks in content arrays.
        content = m.get("content")
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "tool_result":
                    tcid = block.get("tool_use_id") or block.get("id")
                    if tcid:
                        ids.add(str(tcid))
    return ids


# A stub like <tool_result id="t12" .../> is what tier-1 elision produces.
STUB_RE = re.compile(r"""<tool_result\s+[^>]*\bid\s*=\s*"([^"]+)"[^>]*/>""")


def _stub_ids_in_messages(messages: list[dict[str, Any]]) -> set[str]:
    ids: set[str] = set()
    for m in messages:
        content = m.get("content")
        if isinstance(content, str):
            ids.update(STUB_RE.findall(content))
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict):
                    text = block.get("text") or ""
                    if isinstance(text, str):
                        ids.update(STUB_RE.findall(text))
    return ids


@dataclass
class RequestReport:
    index: int
    orig_messages: int
    rewritten_messages: int
    orig_tokens: int
    rewritten_tokens: int
    delta_tokens: int
    pct_saved: float
    elided_tool_result_ids: list[str] = field(default_factory=list)
    error: str | None = None
    http_status: int | None = None


def _post(target: str, body: dict[str, Any], timeout: float) -> tuple[int, dict[str, str], bytes]:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        target,
        data=data,
        method="POST",
        headers={
            "content-type": "application/json",
            DEBUG_REQUEST_HEADER: "1",
            # Disable streaming for the replay path; we only want headers.
            "accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, {k.lower(): v for k, v in resp.getheaders()}, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in (e.headers.items() if e.headers else [])}, e.read() or b""


def _parse_rewritten(headers: dict[str, str]) -> list[dict[str, Any]] | None:
    inline = headers.get(HEADER_REWRITTEN_INLINE)
    if inline:
        try:
            return json.loads(inline)
        except json.JSONDecodeError:
            return None
    sidecar = headers.get(HEADER_REWRITTEN_SIDECAR)
    if sidecar and os.path.exists(sidecar):
        try:
            with open(sidecar, "r", encoding="utf-8") as f:
                return json.load(f)
        except (OSError, json.JSONDecodeError):
            return None
    return None


def _parse_stats(headers: dict[str, str]) -> dict[str, Any]:
    raw = headers.get(HEADER_STATS)
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}


def replay_session(
    session_path: str,
    target: str,
    max_requests: int | None,
    timeout: float,
) -> list[RequestReport]:
    reports: list[RequestReport] = []
    with open(session_path, "r", encoding="utf-8") as f:
        for i, line in enumerate(f):
            if max_requests is not None and i >= max_requests:
                break
            line = line.strip()
            if not line:
                continue
            try:
                body = json.loads(line)
            except json.JSONDecodeError as e:
                reports.append(RequestReport(
                    index=i, orig_messages=0, rewritten_messages=0,
                    orig_tokens=0, rewritten_tokens=0,
                    delta_tokens=0, pct_saved=0.0,
                    error=f"json decode: {e}",
                ))
                continue

            orig_messages = body.get("messages", []) or []
            orig_text = _messages_text(orig_messages)
            orig_ids = _collect_tool_result_ids(orig_messages)

            try:
                status, headers, _payload = _post(target, body, timeout)
            except (urllib.error.URLError, TimeoutError, OSError) as e:
                reports.append(RequestReport(
                    index=i,
                    orig_messages=len(orig_messages),
                    rewritten_messages=0,
                    orig_tokens=_estimate_tokens(orig_text),
                    rewritten_tokens=0,
                    delta_tokens=0,
                    pct_saved=0.0,
                    error=f"transport: {e}",
                ))
                continue

            rewritten = _parse_rewritten(headers) or []
            stats = _parse_stats(headers)

            orig_tokens = int(stats.get("orig_tokens") or _estimate_tokens(orig_text))
            rewritten_text = _messages_text(rewritten) if rewritten else ""
            rewritten_tokens = int(stats.get("rewritten_tokens") or _estimate_tokens(rewritten_text))

            # Elided ids: prefer proxy-reported list; fall back to (orig - rewritten)
            # intersected with stub markers in the rewritten body.
            reported = stats.get("elided_tool_result_ids")
            if isinstance(reported, list):
                elided = [str(x) for x in reported]
            else:
                rewritten_ids = _collect_tool_result_ids(rewritten)
                stub_ids = _stub_ids_in_messages(rewritten)
                elided = sorted((orig_ids - rewritten_ids) | stub_ids)

            delta = orig_tokens - rewritten_tokens
            pct = (delta / orig_tokens * 100.0) if orig_tokens else 0.0

            reports.append(RequestReport(
                index=i,
                orig_messages=len(orig_messages),
                rewritten_messages=len(rewritten),
                orig_tokens=orig_tokens,
                rewritten_tokens=rewritten_tokens,
                delta_tokens=delta,
                pct_saved=round(pct, 2),
                elided_tool_result_ids=elided,
                http_status=status,
                error=None if 200 <= status < 300 else f"http {status}",
            ))
    return reports


def _print_summary(reports: list[RequestReport]) -> None:
    if not reports:
        print("(no requests)")
        return
    headers = ["#", "msgs(o>r)", "tok_orig", "tok_rew", "delta", "%saved", "elided", "err"]
    rows = []
    total_o = total_r = 0
    for r in reports:
        total_o += r.orig_tokens
        total_r += r.rewritten_tokens
        rows.append([
            str(r.index),
            f"{r.orig_messages}>{r.rewritten_messages}",
            str(r.orig_tokens),
            str(r.rewritten_tokens),
            str(r.delta_tokens),
            f"{r.pct_saved:.1f}",
            str(len(r.elided_tool_result_ids)),
            r.error or "",
        ])
    widths = [max(len(h), max(len(row[i]) for row in rows)) for i, h in enumerate(headers)]
    fmt = "  ".join(f"{{:<{w}}}" for w in widths)
    print(fmt.format(*headers))
    print(fmt.format(*["-" * w for w in widths]))
    for row in rows:
        print(fmt.format(*row))
    total_delta = total_o - total_r
    total_pct = (total_delta / total_o * 100.0) if total_o else 0.0
    print()
    print(f"totals: orig={total_o} rewritten={total_r} delta={total_delta} saved={total_pct:.2f}%")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Replay session JSONL through the proxy and diff rewrites.")
    ap.add_argument("--target", required=True, help="Proxy chat-completions URL.")
    ap.add_argument("--session", required=True, help="Path to session JSONL.")
    ap.add_argument("--max", type=int, default=None, help="Limit number of requests.")
    ap.add_argument("--timeout", type=float, default=30.0, help="Per-request timeout (s).")
    ap.add_argument("--out", default=None, help="Optional path to write JSON report.")
    args = ap.parse_args(argv)

    if not os.path.exists(args.session):
        print(f"session not found: {args.session}", file=sys.stderr)
        return 2

    t0 = time.time()
    reports = replay_session(args.session, args.target, args.max, args.timeout)
    elapsed = time.time() - t0

    _print_summary(reports)
    print(f"\nelapsed: {elapsed:.2f}s, requests: {len(reports)}")

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump([asdict(r) for r in reports], f, indent=2)
        print(f"wrote {args.out}")

    return 0 if all(r.error is None for r in reports) else 1


if __name__ == "__main__":
    raise SystemExit(main())
