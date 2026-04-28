#!/usr/bin/env python3
"""Minimal local-Qwen client: pip install openai, then `python clients/python-demo.py`."""
import os, sys, time
from openai import OpenAI

PORT = int(os.environ.get("PORT", 10501))
client = OpenAI(base_url=f"http://127.0.0.1:{PORT}/v1", api_key="no-key-needed")

prompt = " ".join(sys.argv[1:]) or "Write a 4-line haiku about offline computing."

t0 = time.perf_counter()
n = 0
print(f"[port {PORT}] streaming…\n")
stream = client.chat.completions.create(
    model="local",
    messages=[{"role": "user", "content": prompt}],
    stream=True,
    max_tokens=512,
    temperature=0.6,
    top_p=0.95,
)
for chunk in stream:
    delta = chunk.choices[0].delta.content or ""
    print(delta, end="", flush=True)
    n += len(delta.split())
print(f"\n\n— {n/(time.perf_counter()-t0):.1f} word/s (rough)")
