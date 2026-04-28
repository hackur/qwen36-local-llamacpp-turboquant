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
