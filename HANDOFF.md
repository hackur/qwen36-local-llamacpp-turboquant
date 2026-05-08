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

---

## Round 6 — context, KV math, hardening

This round started from a single observation — the 35B-A3B server was being launched with `-c 131072` despite a `n_ctx_train` of 262144 — and ended up touching the per-model knobs, the KV-cache docs (which turned out to be wrong by 4×), the vision launcher, and a launchd-killing `set -u` bug. The compact-and-save workflow finally got proven end-to-end.

### A. Per-model defaults

Generic env-var overrides are fine until the right CTX for one model is wrong for another. Added `configs/model-defaults.env` plus `load_model_defaults` and `rope_args` in `scripts/_common.sh`, wired into `scripts/start-turboquant.sh`. Precedence: explicit env > per-model default > generic default > script-default.

The first beneficiary was `qwen36-35b`: default CTX **131072 → 262144** (its full `n_ctx_train`). Surprise during measurement — KV at turbo3/256K landed at **1344 MiB**, not the ~3 GiB the 11.6 KiB/tok @ 64K extrapolation predicted. Turbo3's fixed overhead amortizes hard at large context, so per-token cost falls as ctx grows.

### B. RoPE/YaRN escape hatch

For the rare case where a 256K session genuinely fills, plumbed `ROPE_SCALING` / `ROPE_SCALE` / `YARN_ORIG_CTX` env vars through `start-turboquant.sh` as `--rope-scaling --rope-scale --yarn-orig-ctx`. The intended workflow:

1. 256K session approaches the wall.
2. Spin up a transient YaRN-2× server on a free port (`ROPE_SCALING=yarn ROPE_SCALE=2.0 YARN_ORIG_CTX=262144`).
3. Ask the model to compact the conversation to JSON; save it.
4. Reload the JSON as the system prompt of a fresh, un-scaled 256K session.

This treats RoPE extrapolation as a one-shot tool, not a steady state.

### C. Compact-and-save, verified

7-message synthetic conversation → 1.4 KB JSON note → fresh session recovered every specific fact when re-loaded. Adopted `snapshots/` as the dump location (gitignored).

### D. Vision memory pre-flight

`scripts/start-vision.sh` now estimates total memory load *before* boot: model GGUF size + mmproj + 1.5 GiB KV scratch + summed RSS of every other live `llama-server` PID + 4 GiB headroom, compared to `hw.memsize`. Aborts unless `FORCE=1`. Sentinel: `# memory-preflight:v1`. The motivation was the obvious one — silently OOMing a 64 GB box because a vision server was launched while the primary was already resident.

### E. Privacy pre-push hook (opt-in)

Carved `scripts/privacy-scan.sh` out of `static-check.sh`. Added `scripts/git-hooks/pre-push` that's intended to be symlinked in by hand — not auto-installed, because we don't surprise contributors with hooks. `Makefile` gained `privacy-scan` and `prepush` targets; `CONTRIBUTING.md` got the one-liner symlink instruction.

### F. KV-cache math was wrong by 4×

The most consequential finding of the round. `docs/kv-cache-math.md`, `docs/architecture.md`, and `docs/context-matrix.md` had been carrying these numbers for Qwen3.6-35B-A3B:

> 64 layers, 8 KV heads, head_dim 128 → ~80 KB f16/tok

Re-reading the GGUF metadata directly:

> **40 blocks, 2 KV heads, head_dim 256, full_attention_interval=4 → only 10 layers carry KV → ~20 KiB f16/tok**

A 4× overstatement. The doc-reported "max 32K @ f16" was actually closer to **256K @ f16**. All three docs corrected.

### G. The launchd-killing bug

`${ROPE_FLAGS[@]}` under `set -u` is fatal on macOS bash 3.2 when the array is empty — which is the no-RoPE common case, i.e. every normal boot. Both occurrences in `start-turboquant.sh` now use `${ROPE_FLAGS[@]+"${ROPE_FLAGS[@]}"}`. The launchd-managed primary had been spin-restarting in a loop until this got patched. Worth remembering the next time we add an array of optional flags.

### H. Misc

- `# port-guard:v1` sentinel added to `_common.sh`'s `ensure_port_free`.
- `docs/system-info.md` date refreshed 2026-04-27 → 2026-05-06.
- `docs/troubleshooting.md` picked up sections for proxy port `:11500`, run-to-run variance, mixed-K/V slowdown, port-guard, and privacy-gate failures.
- `docs/m5-readiness.md` confirms pre-M5 LUT path via existing dogfood logs and tags tensor-API items as wait-for-M5.
- `docs/install-models.md` cosmetic skip-message wording fix.
- `proxy/eval/ab-harness/` scaffold landed (no behaviour yet).

---

## Round 7 — proxy maturation, hooks engine, release prep

The previous round finished with the proxy doing Tier-0/Tier-1 elision and the spec doc gesturing at a dozen unbuilt phases. This round pushed the proxy through Phases 2/3/4/5, ratified the hooks-middleware spec and built the engine behind it, populated the §11 battle-test table from a real A/B harness run, scaffolded the embeddings + summarizer benchmarking infrastructure, audited a thermal-throttle that the user keeps re-discovering, and tightened a handful of operational guard-rails before cutting v0.0.2.

### A. Proxy Phase 2 — recursive summarizer hook

`proxy/src/summarizer.js` plus a Phase 2 hook in `rewrite.js`, gated on `summarizer.url` being set with `mode: shadow|enforce`. Shadow counts what would be replaced; enforce actually replaces. Two design points worth flagging next time someone reads this code:

1. **Shadow=count-only / enforce=replace.** Same shape as the top-level proxy modes, kept deliberately so the operator can stage rollout the same way.
2. **Inline replacement vs persist+dual-link.** We chose inline replacement (the summary takes the slot) over persist-the-original-and-dual-link, because `expand_tool_result` rehydration is already the answer for "give me the full text back" — duplicating that path for prose summaries earns nothing but more state. 8 new unit tests.

### B. Proxy Phase 3 — session keying

`proxy/src/session.js`: `keyForRequest`, `extractStablePrefix`, a TTL-bounded session map, and slot save/restore stubs. Adds a `session:` config block. Stubs because `llama-server` slot save/restore wiring is upstream-dependent and we want the keying primitive landed first so Phase 4 hooks can attach to it. 5 new tests.

### C. Proxy Phase 4/5 — structured notes + sumy fallback

`proxy/src/notes.js` and a Tier-2/3/4 hook in `rewrite.js`. `notes:` and `sumy:` config sections. The full layering ladder is now: **Phase 2 summarizer → Phase 4 structured notes → Phase 5 sumy fallback → Tier 1 elision**, each one degrading gracefully into the next. 6 new tests.

### D. Hooks-middleware spec — ratify, amend, build

The v0.1 spec went through a review (#38, verdict "ratify with amendments") and then a full pass to apply all 16 amendments (#57): per-phase scratch fields, tags read-only, mutation visibility rules, `replace('messages')` writeback, mutate-collision semantics, `HookPhaseClosedError`, inject fallbacks, handler signature pinning, `predicate_module`, §6.5 Handler Resolution, `stream:context-trigger` semantics, §12 byte-identity caveat, §11 variant naming, metric aggregation, `x-rewrite-stats` note, naming convention.

Then the engine itself (#39) — `proxy/src/hooks/{engine, registry, tag-bash-read-elisions, context-pressure-reminder, prose-summarize, once-per-session, session-hint-loader}.js`, wired into `server.js` at four request phases, gated behind a `NULL_HOOKS` sentinel + `hasHooksFor` early-out so a config without a `hooks:` block pays zero per-request cost. `hooks: {enabled, default_timeout_ms, handlers[]}` config. 15 new tests. **MVP scope deviations to remember:** `stream:*` and `response:*` phases are registered but don't fire yet; `HookPhaseClosedError` isn't enforced at runtime; the filter DSL is partial.

### E. A/B harness fixtures + battle-test table populated

`proxy/eval/ab-harness/` got 5 fixtures (~180 KB), `runner.py` extended with a subprocess shim, `aggregate.py` emitting the §11 metric shape, and `proxy/scripts/run-rewrite.js` as the Node CLI shim. Smoke run: 30 cells, 2.1 s, 0 errors, 100% needle + decision preservation; tier0+tier1 was −49.9% on tool-heavy fixtures. The §11 battle-test table in `docs/hooks-middleware.md` is now real numbers, not placeholders.

### F. Embeddings + summarizer benchmarking

- `scripts/start-embed.sh` (sentinel `embed-server:v1`, port 10510, KV f16, `--embedding`) + Makefile target + `docs/api.md` updated. Scaffolded; user picks the embedding model.
- `scripts/bench-summarizer.sh` runs gemma4-e4b vs nemotron-4b vs tiny on 5 inline fixtures using transient ports 10520-22, captures load/prefill/gen tps + summary text, writes `benchmarks/summarizer-bench-<ts>.md`. Decision is the user's; the script just collects the data.

### G. Diagnostics + analyzers

- `scripts/analyze-watermarks.py` (stdlib) reads `~/.cache/qwen-compact/logs/*.jsonl` and reports trigger rate, FPR, and lead time per candidate watermark, with a recommendation to minimise FPR using lead-time as tiebreak. `--csv` flag, Makefile target.
- `scripts/diagnose-variance.sh` snapshotter for the #49 investigation. The neo gen-tok/s variance band turned out to be specific to **128K + 500-tok gen**, and the surviving hypothesis is GPU residency-set / KV eviction churn at 128K — 256K saturates so eviction can't happen, which neatly explains why the asymmetry exists. The script later picked up a follow-up patch wrapping `pmset -g thermlog` in a 2 s `timeout` because it occasionally hung.

### H. Operational guard-rails

- **Mixed K/V guard rail.** `apply_kv_split` helper in `_common.sh` enforces the `KV_K`/`KV_V` env contract, `MIXED_KV_OK=1` silences the warning, sentinel `mixed-kv-guard:v1`. Wired into `start-turboquant.sh` and `start-vision.sh`. (SWEEP.md has been screaming about mixed K/V being slow for two rounds now; this finally puts a hand on the user's shoulder before they boot something dumb.)
- **`--metrics` is opt-in.** `METRICS=1` env in `start-turboquant.sh`, sentinel `metrics-opt-in:v1`. Default is off — `/metrics` was leaking generation counts to anything with localhost access.
- **Quarterly LM Studio re-validation.** `scripts/quarterly-audit.sh`, `configs/launchd-quarterly.template` firing Jan/Apr/Jul/Oct 09:00 local, Makefile target, subsection in `docs/offline-mode.md`. The risk is LM Studio silently re-introducing a phone-home in a future update; we want a calendar reminder, not vigilance.
- **Upstream tracking doc.** `docs/upstream-tracking.md` pins TurboQuant at `11a241d` (2026-04-24) and mainline at `683c5acb9` (2026-04-29), records the q8_0 pins for tiny + gpt-oss-20b, and gives a quarterly recheck recipe. Cross-referenced from `configs/model-defaults.env`.

### I. Live verification

- **Thermal-throttle reproduction.** Three back-to-back A/B runs on the turboquant primary collapsed gen tok/s **13.92 → 7.69 → 4.11** (-45 % run 2, −70 % run 3). Recorded in `benchmarks/RESULTS.md` (2026-05-07 entry). The A/B against baseline f16 is deferred until we have a cool chassis, because there's no point measuring the proxy overhead while the SoC is ramping its own clocks down.
- **Quality-check on turboquant primary.** All 5 prompts correct (1099 math, list-comp, Macbeth, JSON, Mongolia capital).
- **`make audit-offline` on primary.** Zero non-localhost sockets, still.
- **Vision e2e.** `qwen36-neo` + mmproj on `:10503`, base64 PNG → coherent reply in 2.8 s. The Round 6 deferred vision e2e is now done.
- **Editor configs.** `continue.json` and `opencode.json` re-confirmed; the stale "35B-A3B" label in opencode's display name was dropped.
- **Web demo + python demo.** Both still talk to the live primary.

### J. Regression coverage

`sniffUsage` regression test, tool-calling coverage, `expand_tool_result` compaction validation — 6 new proxy tests covering paths the v0.0.1 → Unreleased work had been touching without nets.

### K. Stale 35B-A3B references

`architecture.md` and `context-matrix.md` still carried the old 35B-A3B baselines as if they were primary. Updated to lead with `qwen36-neo`, with the 35B-A3B preserved as fallback context. (Pairs with the kv-cache-math correction from Round 6.)

### L. Two small bugs

- `start-turboquant.sh` had a bash 3.2 empty-array failure in `ROPE_FLAGS` handling on the spin-restart path (sibling of the Round 6 launchd-killing bug, different code site).
- `diagnose-variance.sh` would hang on `pmset -g thermlog`; wrapped in a 2 s `timeout`.

### M. v0.0.2 release prep

`CHANGELOG.md` rotated — Unreleased → `v0.0.2 — 2026-05-07`, with the Round 7 work folded in alongside the prior Round 4–6 entries that were already staged. No tag pushed yet.

### N. Post-tag follow-ups (after `0b873c0`)

The tag landed; the work didn't stop. Six commits chased loose ends and one real bug.

- **Audit fallout (`32a1957`).** The pre-tag audit had drifted on two small things: the proxy README still claimed 126 tests when reality was 129, and `scripts/privacy-scan.sh` had started self-tripping on `docs/troubleshooting.md` (which legitimately contains example personal-path strings as part of the gotchas it documents). Fixed the count and added `:!docs/troubleshooting.md` to the privacy-scan exclude list.
- **`scripts/compare-lmstudio.sh` (`1a4bc16`).** Runbook for a TurboQuant-vs-LM-Studio head-to-head bench. Doesn't run a server itself — guides the operator through stopping the primary, booting LM Studio's runtime against the same GGUF, capturing tok/s, then restoring. Lives alongside the other sustained-load runbooks.
- **Watermark analyzer demo + tuning guide (`65303e4`).** `scripts/analyze-watermarks.py` shipped in Round 7 but had nothing to chew on — real shadow-mode telemetry needs a week to accumulate. Added `scripts/synthesize-telemetry.py` to fabricate plausible JSONL so the analyzer can be exercised end-to-end on a fresh clone, plus `docs/watermark-tuning.md` as the interpretation guide for when real data lands.
- **Summarizer bench, finally run (`5d7cf2d`).** Round 7 scaffolded `bench-summarizer.sh` but didn't run it. Ran it: 4.5 min wall, three candidates (gemma4-e4b, nemotron-4b, tiny) on 5 fixtures. Result: **recommend nemotron-4b** — near-tie with gemma4-e4b on quality (entity preservation, decision-marker survival, unresolved-question capture), marginally faster, and ~3× smaller VRAM, which matters because the summarizer co-resides with the primary. `tiny` produced token-salad on every fixture — server stayed up, output was unusable. Recommendation recorded as a comment in `proxy/config.yaml` and a §11 paragraph in `docs/compaction-strategy.md`; default field not flipped yet (waits for Phase 2 end-to-end).
- **`bench-summarizer.sh` teardown bug (`502fffe`).** The actual surprise of the post-tag pass. The script launched models via `start-turboquant.sh` in the background and stored `$!`. But `start-turboquant.sh` internally does `exec "$BIN" ... | tee "$LOG"` — and the `exec | tee` chain reparents `llama-server` away from the wrapper PID. So `kill $SERVER_PID` killed the wrapper but left the actual server running. After today's bench, three transient servers (gemma4-e4b on `:10520`, nemotron-4b on `:10521`, tiny on `:10522`) survived the script's "stopping…" line. Combined RSS pushed the system to **0.1 GiB free / 95% swap**. Fix: after `wait_health` succeeds, look up the real PID via `lsof -nP -iTCP:$port -sTCP:LISTEN -t` and fall back to `$!` only if that fails. Worth filing under "every long-running script that backgrounds a piped wrapper needs this lookup". The other sustained-load runbooks launch the binary directly, so they were unaffected.
- **100K-needle pass under degraded prefill (`a17d046`).** Last v0.0.2 checklist item. Live primary, `qwen36-neo` turbo3 @131K, recovered the secret password (`fjord-mango-pinwheel-9421`) from a **72 546-token prompt at depth 50%** in 1654 s wall — exact match. Prefill rate was **43.9 tok/s**, roughly half the cool-chassis number seen earlier in the same session on a 30K probe (~93 tok/s). Cause: lingering compressed-swap pressure from the orphan-server incident above (25.8 / 27 GiB swap still in use when the needle test started). Recall correctness held regardless. Smaller probes for the record: 5K @ 50% in 48 s (96 tok/s prefill), 30K @ 50% in 202 s (93 tok/s prefill). The point: TurboQuant's recall is robust even when the chassis is fighting itself for memory; the perf number is the one that suffers.
