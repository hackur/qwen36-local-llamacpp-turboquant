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

The initial audit found both local Git engine checkouts shallow and changed no
engine refs, pins or builds. A later bounded source probe is recorded below;
it also left all working engines unchanged. A portable source merge needs a real common ancestor and careful
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


## Bounded source-port attempt — 2026-11-04

An isolated probe is preserved under `vendor/llama.cpp-candidate-v0.9.0-probe/`.
It is explicitly **incomplete and not runnable**, and is not selected by any
profile. Detailed logs, the patch and source hashes are retained locally under
`logs/engine-candidate/v0.9.0-probe/`. Neither directory is published.

The object caches contain common ancestor
`15586e2d7165570fb3aa7c26e0d442e289ef69de` for the working mainline and fork.
Therefore shallow status alone does not prevent local patch inspection. The
working fork's full delta from that ancestor spans 265 files, with 47,990
insertions and 2,463 deletions; this includes changes beyond KV/MTP and is not
a minimal feature patch.

Current stable upstream v0.9.0 (`cd959bae99ff4bed22bef2604f45241c09bbb8c8`)
is absent from the local object caches. A bounded recursive-tree query consumed
1,114,865 payload bytes. A broad server/CLI build-source selection has 1,200
uncached files totaling 36,146,454 uncompressed bytes. Excluding unrelated GPU
backends still leaves a CPU/Metal-oriented selection of 592 uncached files,
21,878,681 uncompressed bytes. These are source selections, not measured minimum
network requirements; compression and a further-pruned build could reduce them.
No full source download was attempted under the current data constraint.

For a small conflict probe, 12 critical current-upstream files were fetched
(1,834,967 bytes total), each verified against the upstream tree's Git blob
hash. The working pinned fork's corresponding changes were exported into a
186,703-byte local patch and applied with `git apply --3way --index` in the
isolated probe. No working source, binary, engine pin, service or model changed.

### Exact blockers

Seven files remain unmerged:

- `common/speculative.cpp`
- `ggml/include/ggml.h`
- `ggml/src/ggml-cpu/ops.cpp`
- `ggml/src/ggml.c`
- `src/llama-graph.cpp`
- `src/llama-kv-cache.cpp`
- `tools/server/server-context.cpp`

Upstream assigns type ID 43 to `GGML_TYPE_F8_E4M3`; the fork assigns 43 to
`GGML_TYPE_TURBO2_0`. The file-type enum also conflicts: upstream FP8 and the
fork's ConvRot Q8 both use 29. Choosing one side would discard a supported type;
blind renumbering can break serialized weight compatibility and dispatch tables.
The first minimal port should omit unrelated ConvRot and TQ weight formats,
retain upstream serialized IDs, and explicitly design runtime-only KV IDs.

The old monolithic `ggml/src/ggml-metal/ggml-metal.metal` is absent in current
upstream. It now has split `ggml-metal/kernels/*.metal` files for quantization,
flash attention and other operations. The TurboQuant write/read kernels and
host-name registrations need a deliberate port into that structure. Clean
application of a host C++ hunk does not validate shader compatibility.

Speculative decoding, graph/KV integration and server-context conflicts also
need review against current APIs. This 12-file probe omits additional codec,
registration and build files; it cannot be compiled as a complete engine.
There were no existing `test-turbo-quant`, `test-quantize-fns` or
`test-backend-ops` executables in the working fork's build to provide an
immediate baseline. No unresolved candidate code was published.

### Validation matrix and next steps

| Check | Existing setup | Isolated candidate |
| --- | --- | --- |
| Artifacts and launcher dry-runs | All five profiles previously passed; inventory rechecked | No runnable binary |
| Build | Working builds preserved | Not attempted: incomplete source and unresolved core conflicts |
| LFM3 loading/inference/unload | Prior bounded default-thinking check passed | Not attempted |
| Three 9B models loading/inference/unload | Prior bounded checks passed | Not attempted |
| Qwen 27B live operation | Existing PID preserved | No duplicate load or coordinated switch attempted |
| Quantization/backend gates | Test binaries absent from existing build | Not run; no passing claims |
| Automated load/unload/switch matrix | Not newly exercised | Not attempted |

Memory pressure reported only 16% free during this attempt, compared with the
initial audit's 70%. Qwen and poker-related process IDs remained present. No
service was stopped, no model was unloaded, and no inference request was made
for this candidate.

The next implementation step is a complete isolated source checkout with an
agreed transfer budget, then a CPU/Metal-only runtime-KV + adaptive-MTP port that
excludes unrelated weight formats and preserves upstream type IDs. Resolve the
seven conflicts and port the split Metal kernels before attempting a two-job
build. Run codec quality tests and actual CPU/Metal backend write/read cases;
skipped or 0/0 cases do not establish correctness. Then validate bounded LFM3
and 9B loads/inference/unloads serially. A Qwen 27B candidate load and an actual
cross-model switch need a coordinated service window and a fresh memory check.
Retain all existing engine pins, builds and service settings for rollback.
