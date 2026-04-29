#!/usr/bin/env python3
"""Needle-in-haystack at long context.
Usage:  python3 scripts/needle.py <target_tokens> [<port>] [<depth_pct>]
  depth_pct: 50 (default) → middle, 5 → near start, 95 → near end
"""
import json, sys, time, urllib.request

def call(port, prompt, max_tokens=80, timeout=600):
    body = json.dumps({
        "model": "local",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.0,
        "chat_template_kwargs": {"enable_thinking": False},
    }).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
                                 data=body, headers={"Content-Type": "application/json"})
    raw = urllib.request.urlopen(req, timeout=timeout).read().decode()
    return json.loads(raw, strict=False)

def server_ctx(port):
    """Get the server's currently-loaded n_ctx (may be smaller than n_ctx_train)."""
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/props", timeout=5) as r:
            j = json.loads(r.read().decode(), strict=False)
        return int(j.get("default_generation_settings", {}).get("n_ctx", 0))
    except Exception:
        return 0

def main():
    target = int(sys.argv[1]) if len(sys.argv) > 1 else 50_000
    port   = int(sys.argv[2]) if len(sys.argv) > 2 else 10501
    depth  = int(sys.argv[3]) if len(sys.argv) > 3 else 50

    # Clamp target to ~80% of server's loaded context (leave room for instructions + reply)
    loaded_ctx = server_ctx(port)
    if loaded_ctx and target > int(loaded_ctx * 0.8):
        new_target = int(loaded_ctx * 0.8) // 1000 * 1000
        print(f"⚠  target {target} > 80% of server's n_ctx={loaded_ctx}, clamping to {new_target}")
        target = new_target

    NEEDLE = "The secret password is fjord-mango-pinwheel-9421."
    UNIT   = "The quick brown fox jumps over the lazy dog. "
    chars = target * 4
    before_len = chars * depth // 100
    after_len  = chars - before_len
    before = (UNIT * (before_len // len(UNIT) + 1))[:before_len]
    after  = (UNIT * (after_len  // len(UNIT) + 1))[:after_len]
    prompt = f"{before}{NEEDLE}{after}\n\nQuestion: what is the secret password? Reply with the password only."

    print(f"▶ target={target} tok · depth={depth}% · port={port}")
    t0 = time.time()
    r = call(port, prompt)
    dt = time.time() - t0
    ans = r["choices"][0]["message"]["content"].strip()
    t = r.get("timings", {})
    ok = "fjord-mango-pinwheel-9421" in ans
    print(f"  reply: {ans!r}")
    print(f"  prompt_n: {t.get('prompt_n')} · prompt_tps: {t.get('prompt_per_second',0):.1f} · gen_tps: {t.get('predicted_per_second',0):.1f} · wall: {dt:.1f}s")
    print("  ✓ needle recovered" if ok else "  ✗ needle NOT recovered")
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
