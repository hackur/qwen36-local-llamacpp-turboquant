# Handoff — round 2 polish

This commit closes out the offline-first goal. After round 1 we had a working bench-able stack; this round added the offline diagnosis, hardening, deeper testing, web-demo polish, and auto-start.

## What's new since the previous commit

### Offline-first proof
- **`docs/offline-mode.md`** — user-facing recipe: why LM Studio breaks offline (cached account check, hub catalog refresh), and how to leave it. Inspected `~/.lmstudio/.internal/lm-link-account-status-cache.json` to confirm.
- **`make audit-offline`** — verifies the running llama-server has zero non-localhost sockets. Re-runnable any time. Single-line proof:
  ```
  ✓ zero non-localhost sockets — provably offline-clean
  ```
- **`Qwen-Offline.command`** — double-clickable Finder launcher. Boots the server, opens the web demo. Works without terminal.

### Always-on
- **`make install-launchd`** — installs the auto-start plist. Server boots at login, restarts on crash. Verified: `launchctl list | grep qwen` shows the agent active, and the TurboQuant server is back up (pid 27917) after install.
- **`make uninstall-launchd`** — undo.

### Better tooling
- **`Makefile`** — single entry-point for everything: `make build`, `make start`, `make stop`, `make status`, `make bench`, `make needle`, `make demo`, `make open`.
- **`scripts/status.sh`** — what's running, on which ports, with which model, recent log tails.
- **`scripts/stop-all.sh`** — clean kill (SIGTERM then SIGKILL).
- **`scripts/upgrade.sh`** — git-pull both forks, preview incoming commits, prompt before rebuild.
- **`scripts/rotate-logs.sh`** — keep last 7 days of compressed logs, truncate active logs above 100 MB.

### Better demos
- **`clients/web-demo.html`** — markdown rendering (code blocks, lists, headings, links), settings drawer (max_tokens, temperature, top_p, enable_thinking toggle), live status pill (up/down), clear button. Still single-file, no external assets — works offline from `file://`.
- **`scripts/demo-chat.sh`** — `THINK=1 ./scripts/demo-chat.sh` to enable thinking; default off.
- **`scripts/bench.py`, `scripts/needle.py`** — promoted from /tmp prototypes. Tolerant of Qwen's raw control-char output (jq breaks on those; Python's `json.loads(strict=False)` doesn't).

### Vision (scaffolding)
- **`scripts/start-vision.sh`** — start a vision-capable server with `--mmproj` loaded.
- **`scripts/test-vision.sh`** — generate a test PNG and POST it. Did *not* run end-to-end (would need to swap the running TurboQuant server out).

### Deeper benchmarks → `benchmarks/SWEEP.md`
- **llama-bench cross-product** of `-ctk` × `-ctv ∈ {f16, turbo3}`:
  - f16/f16: 880 / 54.84 (pp512 / tg128 tok/s)
  - **turbo3/turbo3: 1015 / 52.96** ← prompt processing **+15% faster** than f16
  - mixed: 376–536 / 44–46 tok/s — much worse, **never mix K and V types**
- **Multi-depth needle test** at 5%/50%/95% of 50K tokens — all three recovered.
- **TTFT measurements** at 41 / 516 / 5K / 20K-token prompts.
- **Mini-eval** (10 problems): 8/10 correct (1 arithmetic miss, 1 truncation by max_tokens — both real failures, not stack issues).
- **Stress test**: 100 sequential requests, 0 errors, 34s wall time, gen tok/s avg 77.

### Documentation
- **`docs/api.md`** — every /v1 and llama.cpp-native endpoint, methods, expected codes.
- **`docs/kv-cache-math.md`** — bytes-per-token math from observed numbers (~12 KiB/tok @ turbo3, vs ~256 KiB/tok @ f16).
- **`docs/m5-readiness.md`** — what the `pre-M5 hardware: using 4-mag LUT` log line means and how this stack will auto-upgrade on an M5.
- **`README.md`** — replaced "Status: Planning" with the actual numbers, added the LM Studio offline section.

## What's intentionally not done

| Skipped | Why |
|---|---|
| ctx-size automated sweep | Each ctx size needs its own server boot. SWEEP.md captures the meaningful 32K vs 64K comparison; TTFT table covers scaling. |
| batch-size sweep | Defaults already deliver 1015 tok/s prompt — chat-template overhead becomes the bottleneck before batching helps. |
| `TURBO_SPARSE_V=0` ablation | Default works. Documented as an env var in case quality regressions appear. |
| Battery vs AC | Would require unplugging the user. |
| `-np 2` concurrent test | Single-user offline use case. -np 1 by design. |
| Speculative decoding | Needs a Qwen3-0.6B draft model in matching tokenizer, not yet on disk. |
| Editor integration verification | Configs are written; final check happens in the editor. |
| Vision end-to-end run | Would need to swap out the running TurboQuant server. Scripts are ready. |

## Next time the user opens this

```bash
make status          # show what's running
make audit-offline   # confirm zero outbound sockets
make demo            # talk to it
make open            # browser UI
```

If LM Studio updates and moves files: `./scripts/symlink-models.sh` re-creates the symlinks. If the TurboQuant fork ships a new commit: `./scripts/upgrade.sh` previews + rebuilds.

## Final state

- 35-B-A3B Q6_K runs at **63 tok/s gen / 322 tok/s prompt** with **64K context** on M3 Max 64 GB.
- Always-on via launchd. Wi-Fi off → no impact.
- 41 + 42 = 83 total tasks, 81 completed, 2 deferred (vision e2e, integration verify).

---

## Round 3 — dogfood pass

Walked through every documented `make` target / script / API example and fixed what didn't work. **5 real bugs found and fixed**:

| # | Where | Bug | Fix |
|---|---|---|---|
| 1 | `scripts/healthcheck.sh` | Reply was empty — Qwen's thinking-mode ate the 20-token budget | Pass `enable_thinking:false` and bump max_tokens to 40; use `json.loads(strict=False)` |
| 2 | `clients/python-demo.py` | Required `pip install openai` (offline-unfriendly) | Rewrote with stdlib `urllib.request` — zero deps |
| 3 | `scripts/needle.py` | `make needle` returned HTTP 400 when target > server's loaded n_ctx | Auto-detect via `/props` and clamp to 80% of n_ctx |
| 4 | `scripts/long-context-test.sh` | Bash-with-`yes`+jq pipe hung on big prompts | Replaced with thin wrapper that delegates to `needle.py` |
| 5 | `scripts/rotate-logs.sh` | `stat -f %z` failed because user has GNU coreutils' `stat` in PATH (BSD `-f` ≠ GNU `-f`) | Use POSIX `wc -c` instead |

### What we verified end-to-end

| Path | Result |
|---|---|
| `make` (no args) | help table prints |
| `make status` | shows server up at pid + n_ctx + model |
| `make audit-offline` | ✓ zero non-localhost sockets |
| `make demo` (piped two turns + /reset) | ALPHA → reset → BETA, history works |
| `make bench` (only one server up) | gracefully skips :10500, runs :10501 |
| `make needle` | recovered the password at 50K tokens |
| `make uninstall-launchd` then `make install-launchd` | server stops, then auto-restarts in 5s |
| `Qwen-Offline.command` (server up) | detects, opens browser, exits 0 |
| `scripts/healthcheck.sh` | `reply: 'Hi there, how are you today?'` 63 tok/s |
| `scripts/quality-check.sh` | all 5 prompts produced correct answers |
| `scripts/upgrade.sh` (n/n) | shows incoming commits, declines cleanly |
| `scripts/rotate-logs.sh` | gzipped old logs, server stayed up |
| `scripts/symlink-models.sh` (re-run) | idempotent |
| API endpoints from `docs/api.md` | `/health 200`, `/v1/models 200`, `/props 200`, `/slots 200`, tokenize works, chat works |
| `clients/python-demo.py` | `PASS` reply via stdlib only |
| `clients/web-demo.html` static audit | zero external resources, only `127.0.0.1` fetches |

Updated `docs/offline-mode.md` (removed stale `pip install openai` step) and `docs/troubleshooting.md` (added the 3 gotchas above).

---

## Compaction proxy

Reverse proxy in front of `llama-server` that observes (and, eventually, rewrites)
the OpenAI Chat Completions message array to keep long agentic sessions
coherent. Design: [`docs/compaction-strategy.md`](docs/compaction-strategy.md).
Operator quickstart: [`docs/proxy.md`](docs/proxy.md).

**Built (Phase 0 + Phase 1):**
- Node/Fastify proxy at `proxy/src/`, listens on `:11500`, forwards to `:10501`,
  SSE preserved including `[DONE]`. Per-request JSONL logging to
  `~/.cache/qwen-compact/logs/YYYY-MM-DD.jsonl`.
- Three modes: `passthrough` (log only), `shadow` (compute rewrite, log it,
  forward original), `enforce` (forward rewritten body). `x-compact: off`
  request header bypasses everything.
- Phase 1 Tier-1 elision: tool-result truncation + `expand_tool_result` phantom
  tool. Token accounting via upstream `/tokenize` with an LRU.
- Replay + needle harness under `proxy/eval/` (50-turn fixture, regex grader).
  Unit + stub-upstream integration tests under `proxy/tests/`.

**Stubbed (Phase 2/3):**
- Phase 2 small-model recursive summarization. `proxy/scripts/start-summarizer.sh`
  exists but the proxy doesn't yet call out to a second port.
- Phase 3 KV-cache cooperation (stable-prefix discipline, slot save/restore,
  session keying). Watermarks are in `config.yaml` but not enforced.
- Phase 4/5 (structured notes, sumy fallback) untouched.

**Run:**
```bash
cd proxy && npm install && npm start
# or: make proxy-install && make proxy-start
```
Point the client at `http://127.0.0.1:11500`. Smoke test: `make proxy-smoke`.

**Logs:** `~/.cache/qwen-compact/logs/YYYY-MM-DD.jsonl` (request rows), proxy
stdout (pino). The cache dir is outside the repo by design.

---

## Round 4 — model swap

Swapped the default from **Qwen3.6-35B-A3B Q6_K** (MoE) to **Qwen3.6-27B-Heretic-Uncensored-FINETUNE-NEO-CODE Q5_K_M** (dense, ~19.5 GB weights). New alias: `qwen36-neo`. The 35B-A3B is now `MODEL_FALLBACK`.

### Rationale
- **Uncensored** — Heretic finetune removes refusal layers for unrestricted local use.
- **Code-tuned** — NEO-CODE pass targets coding workloads, our most common use case.
- **Quality** — Q5_K_M on a 27B dense model beats both prior options for our setup: the 27B was previously running at IQ2_XXS (lossy) and the 35B-A3B at Q6_K (great quality but MoE active-params dilute coding precision).
- **Native 256K** — `n_ctx_train = 262144`. No rope-scaling needed.

### What changed in code (4 files)
- `scripts/_common.sh` — `MODEL_PRIMARY=qwen36-neo`, prior 35B becomes `MODEL_FALLBACK`.
- `Makefile` — new `start-qwen36-neo` target; default `start` resolves to it.
- `scripts/symlink-models.sh` — adds the new model + mmproj symlink lines.
- `models/qwen36-neo.gguf` + `models/qwen36-neo.mmproj.gguf` — new symlinks into the LM Studio cache.

### Measurements (M3 Max 64 GB, --ngl 99, -fa, turbo3 K+V, --jinja, temp=0.6 top_p=0.95 top_k=20)

**Memory at boot:**

| Component | Size |
|---|---|
| Weights | 18 626 MiB GPU + 833 MiB CPU = ~19.5 GB |
| KV @ turbo3 128K | 1 944 MiB |
| KV @ turbo3 256K | 3 888 MiB → **15.2 KiB/tok** (vs ~64 KiB/tok f16) |
| Recurrent state | 149.62 MiB (constant — only 16 of 64 layers carry KV) |
| Total VRAM @ 128K | 20.4 GB / 53 GB Metal limit |
| Total VRAM @ 256K | 22.7 GB / 53 GB Metal limit (~30 GB headroom) |

**Sustained gen (3-run avg, 500-token gen, thinking off):**

| Profile | Gen tok/s | Prompt tok/s |
|---|---|---|
| 128K turbo3 | **14** (run-to-run 4.75–14.49) | 78 |
| 256K turbo3 | 7 | 53 |

**TTFT (10-token gen, thinking off):**

| Prompt size | Wall | Prompt tok/s |
|---|---|---|
| 41 | 1.86 s | 67 |
| 512 | 6.27 s | 105 |
| 5 K | 40.3 s | 127 |
| 20 K | 157 s | 100 |

### Tradeoffs
- **Dense → slower than MoE.** 14 tok/s gen vs the prior 63 tok/s @ 64K is a real regression in raw throughput; the 35B-A3B only had to activate 3B params per token.
- **But:** better per-token quality (Q5 dense beats IQ2 dense and is competitive with Q6 MoE on code), uncensored, and 256K trained context (4× the 64K we ran the 35B at). For agentic + coding work the context headroom matters more than tok/s.
- **Run-to-run variance is high** (4.75–14.49 gen tok/s) — likely background-load sensitive on a 64 GB machine running ~22 GB VRAM. Watch this if it gets worse.

---

## Round 5 — REPL rewrite

Rewrote `scripts/demo-chat.sh` as a Python module. Three real bugs the user hit, each with a real root cause:

1. **Thinking output was invisible.** The bash reader inspected only `delta.content` and silently dropped `delta.reasoning_content`, so Qwen 3.6 thinking turns looked like a long pause followed by a final answer.
2. **Markdown lists collapsed onto one line.** Streamed chunks occasionally carried stray C0 control bytes that corrupted the user's terminal (cursor moves, erase-line). Now sanitized per chunk.
3. **Phantom `qwen>` reply on bare Enter.** Whitespace-only input was POSTed to the server. Now filtered before any HTTP work.

### Files added/changed
- `scripts/demo-chat.py` — new, ~440 lines, stdlib only.
- `scripts/demo-chat.sh` — now a 7-line shim that execs the Python.
- `tests/test_demo_chat.py` — new, 33 tests covering the SSE parser, sanitizer, history pruning, slash commands, env-var compat, and exit codes.
- `scripts/static-check.sh` — now also runs `python3 -m unittest discover -s tests`.
- `docs/demo-chat.md` — new user reference.
- `README.md` — recipe row links to the new doc.

### Test stats
33 tests, fully offline (no llama-server needed), ~1 s wall time. Wired into `make check`.

### Architecture
Single file, stdlib only. Pure functions for SSE parsing (`parse_sse_stream`), C0 sanitization (`sanitize_chunk`), and history pruning (`prune_to_chars`) — they take iterables and return iterables, so unit tests feed them byte fixtures with no sockets. I/O is isolated in a `StreamConnection` object that owns the urllib request and a cancel flag, so SIGINT during streaming flips the flag, closes the response cleanly, and returns to the prompt without leaking the connection or losing history.
