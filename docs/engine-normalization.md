# Engine normalization audit — 2026-11-04

The control interface is normalized by scripts/models.py, but the engines,
source revisions, flags and service lifecycle are deliberately not identical.

| Profile | Source/build | Runtime and lifecycle |
| --- | --- | --- |
| qwen38 (27B Q8_0) | TurboQuant cfd7bde3f4f740d08d68a2dfcf4200b24af988fd | configs/runtime.env; :10501; q8_0 K/turbo3 V; adaptive chained MTP; BF16 projector; existing login agent or foreground |
| lfm3-1.7b Q8_0 | Official b11960 / 8642541b255bfb5dc39cd351a178be09013a55d6 | independent launcher :10502; f16 KV; native template; default thinking; no MTP/projector/agent tools |
| Crow, MiMo and Journalist 9B | Mainline 95b8e33e16bb9a60de780a70930ebf729db6a90a | independent launcher :10502; f16 KV; text-only; no MTP/projector/agent tools |

Use `python3 scripts/models.py list` and `start <profile> --dry-run` to inspect
commands. Foreground Ctrl+C unloads the selected run; load another afterward.
The shared launcher preserves existing services; it does not stop arbitrary
servers to satisfy a switch. The running primary must be unloaded through its
existing service controls during coordinated downtime, not by killing its PID
while KeepAlive remains active. Legacy make switch stops the primary stack.
No automatic routing or enforcement was enabled by this normalization.

## Upstream and fork inspection

The [latest stable upstream API](https://api.github.com/repos/ggml-org/llama.cpp/releases/latest)
reported v0.9.0, cd959bae99ff4bed22bef2604f45241c09bbb8c8.
The [TurboQuant feature branch](https://github.com/TheTom/llama-cpp-turboquant/tree/feature/turboquant-kv-cache)
reported 643956891dfdf51aecdbd05ca508dd21e21e8195. Small reads of their
src/llama-arch.cpp show LFM3 registered upstream, absent from the current fork.
The working pinned fork includes custom adaptive MTP and TurboQuant KV code.
Both source licenses inspected are MIT; model licenses remain independent.

Both local Git engine checkouts are shallow. No engine refs were fetched or
merged, no pins were changed, and no new engine/model downloads or builds were
performed. A portable source merge needs a real common ancestor and careful
review of graph, KV, speculative decoding and Metal changes. Architecture
registration alone does not establish compatibility of custom MTP/quantization.

## Concrete paths and rollback

1. Use the shared entry point with the existing proven per-model engines now.
2. Validate a separate current-upstream candidate for all profiles using standard
   KV and no fork-specific MTP first; this sacrifices fork-only features unless
   independently demonstrated. Do not replace the primary to run the experiment.
3. Port the fork changes into an isolated current-upstream candidate checkout,
   fetching necessary history only after connectivity/data constraints are clear.
   Build separately, compare flags/tensors and run bounded per-model acceptance
   checks before considering an engine-pin update. Do not force a conflicted merge.

Preserve the existing binaries, configs/upstream.env pins, model files and login
service. Rollback a candidate by discarding its separate directory, leaving those
unchanged. Any later service change must record the previous model, ports,
projector, KV, MTP and context settings and restore them through service controls.

The inspected Mac is an M3 Max with 64 GiB unified memory. Qwen and poker-related
processes were running during this audit and were not restarted. Memory pressure
reported 70% free at inspection; that is not a guarantee that every full-context
combination fits. The primary's documented footprint is roughly 35 GiB at native
context. Candidate checks should use short contexts, two CPU threads, bounded
outputs and serial model loads, coordinating any primary downtime explicitly.

## Validation and limits

All five shared-entry dry-runs resolve available artifacts and preserve distinct
features. Current preflight, Python and proxy suites passed. Prior bounded local
inference verified all four independent models; LFM3's thinking-disabled failures
remain documented. No new live model switch or upstream candidate inference was
performed during this audit to avoid disturbing the current workloads.
OpenClaw gateway health and CLI flags were checked; no browser tab manipulation
or live collection was performed. Capture tests use synthetic offline fixtures.
