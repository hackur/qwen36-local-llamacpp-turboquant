#!/usr/bin/env python3
"""Needle-in-haystack at long context.
Usage:  python3 scripts/needle.py <target_tokens> [<port>] [<depth_pct>]
  depth_pct: 50 (default) → middle, 5 → near start, 95 → near end
"""
import argparse, json, sys, time, urllib.request


def _port(s):
    try:
        v = int(s)
    except ValueError:
        raise argparse.ArgumentTypeError(f"port must be an integer (got {s!r})")
    if not 1 <= v <= 65535:
        raise argparse.ArgumentTypeError(f"port must be in 1..65535 (got {v})")
    return v


def _depth(s):
    try:
        v = int(s)
    except ValueError:
        raise argparse.ArgumentTypeError(f"depth_pct must be an integer (got {s!r})")
    if not 0 <= v <= 100:
        raise argparse.ArgumentTypeError(f"depth_pct must be in 0..100 (got {v})")
    return v


def _target(s):
    try:
        v = int(s)
    except ValueError:
        raise argparse.ArgumentTypeError(f"target_tokens must be an integer (got {s!r})")
    if v < 1:
        raise argparse.ArgumentTypeError(f"target_tokens must be >= 1 (got {v})")
    return v

def call(port, prompt, max_tokens=80, timeout=600):
    body = json.dumps({
        "model": "qwen3.8-local",
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
    ap = argparse.ArgumentParser(
        prog="needle.py",
        description="Needle-in-haystack at long context.",
    )
    ap.add_argument("target", nargs="?", type=_target, default=50_000,
                    help="target prompt size in tokens (default: 50000)")
    ap.add_argument("port", nargs="?", type=_port, default=10501,
                    help="llama-server port, 1..65535 (default: 10501)")
    ap.add_argument("depth", nargs="?", type=_depth, default=50,
                    help="needle depth percent, 0..100 (default: 50)")
    args = ap.parse_args()
    target, port, depth = args.target, args.port, args.depth

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
