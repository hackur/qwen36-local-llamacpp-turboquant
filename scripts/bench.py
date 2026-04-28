#!/usr/bin/env python3
"""A/B benchmark — robust to Qwen's raw control-char output (which jq rejects).
Usage:  python3 scripts/bench.py <port> [<label>]
"""
import json, sys, time, urllib.request, urllib.error

PROMPT = ("Explain in detail how transformer attention mechanisms work. "
          "Cover self-attention, multi-head attention, key-query-value matrices, "
          "and positional encoding. Write at least 400 words.")

def call(port, prompt, max_tokens=500, think=False):
    body = json.dumps({
        "model": "local",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "chat_template_kwargs": {"enable_thinking": think},
    }).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
                                 data=body, headers={"Content-Type": "application/json"})
    raw = urllib.request.urlopen(req, timeout=300).read().decode()
    return json.loads(raw, strict=False)  # strict=False → tolerate raw \n in strings

def bench(port, label, runs=3):
    print(f"=== {label} (port {port}) ===")
    try: call(port, "hi", max_tokens=5)
    except Exception as e:
        print(f"warmup failed: {e}"); return None
    speeds, ppss = [], []
    for i in range(1, runs + 1):
        t0 = time.time()
        r = call(port, PROMPT)
        dt = time.time() - t0
        t = r.get("timings", {})
        tps = t.get("predicted_per_second", 0)
        pps = t.get("prompt_per_second", 0)
        n   = t.get("predicted_n", 0)
        speeds.append(tps); ppss.append(pps)
        print(f"  run {i}: {tps:.2f} tok/s gen · {pps:.1f} tok/s prompt · n={n} · wall={dt:.1f}s")
    avg_g = sum(speeds) / len(speeds)
    avg_p = sum(ppss) / len(ppss)
    print(f"  avg gen: {avg_g:.2f} tok/s | avg prompt: {avg_p:.1f} tok/s\n")
    return {"label": label, "port": port, "gen_avg": avg_g, "prompt_avg": avg_p,
            "gen_runs": speeds, "prompt_runs": ppss}

if __name__ == "__main__":
    port = int(sys.argv[1])
    label = sys.argv[2] if len(sys.argv) > 2 else f"port {port}"
    bench(port, label)
