# Changelog

## 2026-11-04 — Local model harness

- Broaden the project contract to model profiles, proxy, classifier, browser
  tools and source-preserving handoffs; prefer the installed OpenClaw CLI.
- Add a common foreground model entry point, preserving per-engine features
  and the working Qwen/LFM3/9B builds; document upstream-port options.
- Archive complete supplied browser captures with provenance, hashes, readable
  views and explicit handoff truncation. Mark bounded research previews.
- Include the pending service/lifecycle improvements and experimental profiles;
  fix baseline defaults, text-only projector handling and model-switch helpers.
- Keep private artifacts ignored and scan feature-branch history before pushes.


## Unreleased

### Proxy tool-set routing (Phase 7)

- The `tool_filter` section in `proxy/config.yaml` (checked in as `shadow`)
  adds a `toolset` choice question to the SAME single Laya `/v1/systemone`
  pass that answers route classification, so the classifier hot path costs
  one call per request regardless of how many consumers are active. Its
  `local_url` / `model` (empty = reuse the `jev` section's) apply to the
  shared call, and the timeout is the max of both sections' timeouts.
- The `taxonomy` maps each label to a list of tool names to keep (or the
  string `all` = never filter). Tune the labels and names to your harness's
  actual tool names; labels unknown to the taxonomy never pass the gate.
- Gate: choice is `all`, the label maps to `all`, or the label is in the
  taxonomy with confidence >= `tool_filter.confidence` (default 0.6).
  `enforce` mode then forwards the request with ONLY that set's tools; the
  checked-in `shadow` mode records the decision instead. Per-request
  telemetry gains a `rewrite.tool_filter` entry
  `{choice, confidence, passes, mode, selected, dropped}`.
- Fails open everywhere: classifier down, timeout, low confidence, unknown
  label, or a request with no tools leaves the forwarded tool list
  unchanged.
- `proxy/src/jev.js`: `routeLocalRequest` now accepts `toolsetCriteria` and
  returns `toolset` / `toolsetConfidence`; the question builder is exported
  as `buildRouteQuestions` so callers and tests share one taxonomy source.
- New `proxy/tests/tool-filter.test.js`: shadow, enforce, low-confidence,
  unknown-label, `all`, no-tools, and classifier-down (fail-open) cases.
- `scripts/laya-server.py` exits with an actionable message when the pinned
  checkpoint cache is missing or incomplete (`make laya-download` first),
  instead of a raw huggingface_hub traceback inside the LaunchAgent.
- `docs/laya.md` gains a Tool-set routing section; `docs/proxy.md` notes the
  shared pass and the `tool_filter` capability.

### Local Laya classifier service

- Added `scripts/laya.sh`, `scripts/laya-server.py`, and
  `scripts/laya-download.py`: a pinned local Laya typed-decisions
  classifier served on `127.0.0.1:18000` through a `com.local.qwen.laya`
  login agent. The checkpoint (`convaiinnovations/laya-typed-decisions`
  @ `e929ae5c`) is hash-verified at download time, served offline with
  `HF_HUB_OFFLINE=1`, and unpinned/`jev-latest` requests are pinned to the
  installed checkpoint.
- The proxy's JEV gate now points at the local service: `jev.local_url` is
  `http://127.0.0.1:18000`, `jev.model` is `typed-decisions`, and the mode
  is `local-only` so a dead classifier is a hard local miss rather than a
  TypeSafe cloud fallback. Requests carry the model pin in the
  `/v1/systemone` body, and `/proxy/info` plus the per-request rewrite
  telemetry expose `jev.model`, `jev.local_url`, `jev_route`, and
  `jev_confidence`.
- The checked-in proxy mode is now `shadow`: the classifier and candidate
  rewrite are evaluated and logged while the ORIGINAL request is forwarded
  upstream. `enforce` remains opt-in behind the replay + needle quality
  gates in `docs/compaction-strategy.md`.
- New Makefile targets: `laya-install`, `laya-download`, `laya-start`,
  `laya-stop`, `laya-status`, `laya-smoke`; `make status` reports the
  `:18000` listener. Setup and acceptance evidence are in `docs/laya.md`.

### Service and stop controls

- Added `scripts/service.sh` and Makefile targets `service-status`,
  `service-register`, `service-start`, `service-stop`, `service-restart`,
  and `service-unregister` for the `com.local.qwen3-8.turboquant` login
  agent. Registration preserves an existing installed plist; stop unloads
  the job but retains it. `install-launchd`/`uninstall-launchd` remain as
  aliases.
- `make stop` now stops the compaction proxy, the launchd agent, and the
  repo's model servers. Added `make proxy-stop` (port-anchored stop of the
  `:11500` proxy) and a `--processes-only` escape hatch on
  `scripts/stop-all.sh`. The model-server scan now uses `ps -axww` plus an
  anchored vendor-path match because `pgrep -f` cannot see the llama-server
  700+ character command line.
- `make info` distinguishes a registered-but-stopped agent from an
  unregistered one.

### Proxy and operator guidance

- Documented the separate llama.cpp WebUI MCP proxy and optional Node
  compaction proxy, including direct client routing and default passthrough.
- Added the optional JEV/Laya classifier integration and standalone research
  script. The classifier gate stays disabled until `jev.local_url` is set;
  Laya is not launched by this project.
- Exposed proxy mode and classifier-gate state through `make status` and
  `/proxy/info`; clarified current versus configured context.
- Cleared inherited external MCP configuration in `make start-offline`.
- Updated the Node proxy's `js-yaml` dependency to 5.4.2.

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
- Removed the orphan root npm lock; the proxy still supports Node 20+.
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
