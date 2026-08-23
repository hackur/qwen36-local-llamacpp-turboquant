# Changelog

## Unreleased

### Qwen3.8-only runtime

- Removed every legacy model alias, sidecar, symlink, launcher, template, and
  benchmark suite. The project now accepts only Qwen3.8-27B Q8_0 and its BF16
  projector.
- Replaced distributed model defaults with `configs/runtime.env`.
- Unified text and vision on `:10501` with explicit q8_0/turbo3 KV.
- Enabled preserved reasoning, metrics, native agent tools, and the WebUI MCP
  proxy by default; added `make start-offline` for the restricted profile.
- Enabled the fork's Metal-validated adaptive chained MTP implementation with
  a 3-token floor and 8-token ceiling.
- Fixed baseline `--dry-run` and added behavioral launcher tests.
- Replaced the benchmark TUI spawn stub with a real detached runner and a
  Qwen3.8-only controlled-comparison suite.
- Removed the external supergateway bridges and small summarizer sidecar. The
  current server has native tools/direct MCP support; the proxy can summarize
  through the same Qwen3.8 upstream.
- Removed the orphan root npm lock and moved Node guidance to current LTS.
- Kept all testing local; no hosted CI workflow is present or planned.
- Refreshed the locally built engine pins to llama.cpp `95b8e33e16` and
  TurboQuant `cfd7bde3f` after full-feature runtime checks and a prior-pin
  throughput control.
- Made `make quality` fail when the full runtime is unavailable instead of
  silently emitting empty baseline output, and made `make bench` default to the
  documented five runs.
- Passed the accepted build's 50K recall probe at 44,486 actual prompt tokens
  while the native 262,144-token window was loaded.
- Added a failing ten-case model acceptance gate with Qwen3.8's official
  thinking/non-thinking sampling profiles; the accepted build passes 10/10.

## v0.0.2 — 2026-05-07

Historical multi-model release. Superseded by the Qwen3.8-only architecture;
see tag `v0.0.2` for its exact documentation and implementation.

## v0.0.1 — 2026-04-29

Initial local llama.cpp/TurboQuant proof of concept. See tag `v0.0.1`.
