# Upstream Tracking

The two inference engines vendored in this repo are kept on their current
upstream branches and rebuilt together by `make upgrade`. The accepted
revisions live in `configs/upstream.env` so the working stack is reproducible.

**Last checked:** 2026-08-20 (network fetch, clean rebuild, Qwen3.8 live test)

## Forks we care about

| Fork | Path | Branch | Pinned commit | Commit date | Subject |
|---|---|---|---|---|---|
| TurboQuant (TheTom) | `vendor/llama-cpp-turboquant/` | `feature/turboquant-kv-cache` | `bd1bf025fc55ffa1fcb2ba6d8bb8805f35671d1f` | 2026-08-19 | current branch tip |
| llama.cpp mainline | `vendor/llama.cpp-mainline/` | `master` | `681c29d36a13be54d317ee147b272da9163dbef3` | 2026-08-20 | current branch tip |

This TurboQuant revision loads Qwen3.8, supports its embedded MTP head via
`--spec-type draft-mtp`, supports the vision projector, and exposes turbo2/3/4
KV types. The April 2026 revision previously pinned here could not load the
model because it treated Qwen3.8's MTP layer as an ordinary transformer block.

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

## Updating both engines

When you want to test whether the fork can drop these q8_0 pins:

```bash
make upgrade
```

The upgrade script refuses dirty vendor checkouts, resets each vendor directory
to its configured upstream branch tip, rebuilds both engines, and prints the
verified revisions. Update `configs/upstream.env` only after the live smoke tests
pass. The vendor branches are engine implementation details; the parent project
has one canonical branch, `main`.
