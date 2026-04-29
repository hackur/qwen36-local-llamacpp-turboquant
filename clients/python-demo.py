#!/usr/bin/env python3
"""Minimal local-Qwen client. Zero dependencies — stdlib only.
Usage:  python3 clients/python-demo.py [your prompt here]
Env:    PORT (default 10501)
"""
import json, os, sys, time, urllib.request

PORT = int(os.environ.get("PORT", 10501))
URL = f"http://127.0.0.1:{PORT}/v1/chat/completions"

prompt = " ".join(sys.argv[1:]) or "Write a 4-line haiku about offline computing."

body = json.dumps({
    "model": "local",
    "messages": [{"role": "user", "content": prompt}],
    "stream": True,
    "max_tokens": 512,
    "temperature": 0.6,
    "top_p": 0.95,
    "chat_template_kwargs": {"enable_thinking": False},
}).encode()

req = urllib.request.Request(URL, data=body, headers={"Content-Type": "application/json"})

t0 = time.perf_counter()
n = 0
print(f"[port {PORT}] streaming…\n")
with urllib.request.urlopen(req, timeout=300) as resp:
    for raw in resp:
        line = raw.decode().rstrip()
        if not line.startswith("data: "):
            continue
        payload = line[6:]
        if payload == "[DONE]":
            break
        try:
            chunk = json.loads(payload, strict=False)
        except json.JSONDecodeError:
            continue
        delta = chunk["choices"][0].get("delta", {}).get("content") or ""
        print(delta, end="", flush=True)
        n += len(delta.split())
print(f"\n\n— {n/(time.perf_counter()-t0):.1f} word/s (rough)")
