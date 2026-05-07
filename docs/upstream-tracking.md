# Upstream Tracking

Read-only audit of the two llama.cpp forks vendored in this repo, plus the
known upstream-blocked issues that force `tiny` and `gpt-oss-20b` onto
`q8_0` KV instead of `turbo3`.

**Last checked:** 2026-05-07 (no network — git-only audit)

## Forks we care about

| Fork | Path | Branch | Pinned commit | Commit date | Subject |
|---|---|---|---|---|---|
| TurboQuant (TheTom) | `vendor/llama-cpp-turboquant/` | `feature/turboquant-kv-cache` | `11a241d` | 2026-04-24 | Merge PR #105 — `cuda: disable sparse V skip (warp divergence regression)` |
| llama.cpp mainline | `vendor/llama.cpp-mainline/` | `master` | `683c5acb9` | 2026-04-29 | `spec : disacard last drafted token with low prob (#22506)` |

The TurboQuant fork's most recent upstream sync is `67559e5 Upstream sync to
b8871 (64 commits)` — so it lags mainline by roughly the commits between
`b8871` and `683c5acb9` (a few weeks of mainline activity at the time of this
check; the actively-developed path on the fork is CUDA, per its recent
history).

## Known issues affecting us

Both manifest as `Abort trap: 6` during model load when `-ctk turbo3 -ctv
turbo3` is requested. They are documented in
[`docs/troubleshooting.md`](./troubleshooting.md) (the table under
"`Abort trap: 6` during model load") and the workaround is pinned in
[`configs/model-defaults.env`](../configs/model-defaults.env).

### 1. Small head-dim — `tiny` (TinyLlama 1.1B)

- **Symptom:** `Abort trap: 6` immediately on model load with `KV=turbo3` on
  Metal (M3 Max). The turbo3 attention kernel doesn't accept the model's
  head-dim.
- **Affected model:** `tiny`.
- **Workaround:** `KV=q8_0` (pinned in `configs/model-defaults.env`).
- **Check whether upstream has fixed it:**
  ```bash
  git -C vendor/llama-cpp-turboquant log --grep='head_dim\|head-dim\|tiny' --oneline | head -5
  ```

### 2. MXFP4 weights — `gpt-oss-20b`

- **Symptom:** `Abort trap: 6` on load. The turbo3 path doesn't dispatch for
  MXFP4-quantized weights.
- **Affected model:** `gpt-oss-20b`.
- **Workaround:** `KV=q8_0` (pinned in `configs/model-defaults.env`).
- **Check whether upstream has fixed it:**
  ```bash
  git -C vendor/llama-cpp-turboquant log --grep='mxfp4\|MXFP4' --oneline | head -5
  ```

## Quarterly recheck

When you want to test whether the fork can drop these q8_0 pins:

```bash
# 1. Pull latest TurboQuant + mainline (network required at this step only)
git -C vendor/llama-cpp-turboquant fetch origin && \
git -C vendor/llama-cpp-turboquant log --oneline HEAD..origin/feature/turboquant-kv-cache | head -40
git -C vendor/llama.cpp-mainline    fetch origin && \
git -C vendor/llama.cpp-mainline    log --oneline HEAD..origin/master | head -40

# 2. If anything looks promising, rebuild then probe both blocked models
#    with KV=turbo3 (override the per-alias q8_0 pin):
make build
MODEL=tiny        KV=turbo3 ./scripts/start-turboquant.sh > logs/probe-tiny.log        2>&1 &
MODEL=gpt-oss-20b KV=turbo3 ./scripts/start-turboquant.sh > logs/probe-gpt-oss-20b.log 2>&1 &

# 3. Success = server reaches "HTTP server listening" and a /v1/chat/completions
#    round-trip returns 200 without "Abort trap: 6" in the log. If both pass,
#    flip KV from q8_0 -> turbo3 in configs/model-defaults.env for those two
#    aliases and update "Last checked" at the top of this doc.
```
