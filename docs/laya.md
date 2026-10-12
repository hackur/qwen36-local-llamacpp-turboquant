# Local Laya classifier

Laya runs on `http://127.0.0.1:18000`, using upstream `laya[serve]==0.3.25`
with PyTorch 2.12.0 in the isolated `vendor/laya-venv` Python 3.13 environment. The checkpoint is
`convaiinnovations/laya-typed-decisions`, revision
`e929ae5cf69bc34259cd2f95c9e91145b818b1f0` (Apache-2.0).
The download command checks the 842,609,220-byte weight file's SHA-256;
startup also verifies its digest and resolves the pinned snapshot offline.
Only this checkpoint is preloaded. The service uses CPU with eight threads.

```bash
make laya-install    # first setup: dependencies, download, verify
make laya-start      # launchd service, restarts on failure and at login
make laya-status    # actual service / resident-checkpoint health
make laya-smoke     # real choice, score, noul and proxy-client inference
make laya-stop      # unload service; keep its login plist
make laya-verify    # re-verify the cached checkpoint (fully offline)
```

`make laya-start` refuses to start when the pinned checkpoint is missing
from the local cache, because the service runs with `HF_HUB_OFFLINE=1`:
a cold start would otherwise fail inside the LaunchAgent with a
huggingface_hub traceback instead of an actionable message. Run
`make laya-download` (or `make laya-install`) first, then
`make laya-start`.

## Offline notes

No internet is required once `make laya-install` has completed once:
the checkpoint lives in the huggingface_hub cache and the service is
pinned to it with `local_files_only`. Re-verify any time with
`make laya-verify` (no network, re-hashes the cached weights). If the
machine is rebuilt or the cache is cleared, `make laya-download` is the
only step that needs the network. `proxy/node_modules` likewise must be
installed with `npm ci` while the registry is reachable; the checked-in
`package-lock.json` pins pino 10.4.0, js-yaml 5.4.2, and friends.

Logs are in `logs/laya.log`. `scripts/laya.sh foreground` runs interactively.
The service binds only to loopback and makes no cloud classifier calls.
The upstream HTTP implementation serves `POST /v1/systemone` and `GET /health`.
Send `model: "typed-decisions"` to select the installed checkpoint explicitly.
Requests with no checkpoint pin (including the `jev-latest` alias) use this same
checkpoint. Other explicitly selected checkpoints are not installed by this
setup and offline requests requiring them fail rather than downloading.

`proxy/config.yaml` enables the local-only classifier and selects shadow mode.
In shadow mode the proxy evaluates the classifier and candidate rewrite, records
`rewrite.jev_route` / `rewrite.jev_confidence`, and forwards the original request.
Use `mode: enforce` to apply the candidate rewrite. Direct traffic to `:10501`
bypasses the Node proxy; send chat requests to `:11500` to use Laya.

The classifier chooses a handler label, reasoning probability and risk score.
The existing rewrite logic uses only `compact` at confidence >= 0.6 to tighten
compaction thresholds. It does not switch the main language model or execute
tools. Classifier errors fail open. The model's 1024-token context also limits
how much of the latest user message it can assess; this is not a classification
of the entire Qwen conversation.

## Acceptance observed 2026-10-03

The downloaded weight size and SHA-256 matched the pinned Hub artifact. Real
CPU inference passed `make laya-smoke`: billing triage, urgency score,
cancellation probability and the proxy's three-question route client completed
in 474 ms combined. A `jev-latest` HTTP request also selected the pinned model
and returned billing. A live chat request through `:11500` recorded a local
classifier decision and returned Qwen's correct arithmetic answer in 1.31 s.
Evidence is in `logs/laya-smoke.json` and `logs/laya-live-acceptance.json`.
All 143 proxy tests and `make check` passed.

The route classifier chose `compact` with low confidence on simple lookup and
arithmetic inputs (0.0662 and 0.041). These samples establish the running service
and integration, not routing accuracy. Keep shadow mode until a representative
evaluation supports applying its decisions. The existing 0.6 compaction gate
did not activate on these samples.

Upstream: https://github.com/NandhaKishorM/laya
Checkpoint: https://huggingface.co/convaiinnovations/laya-typed-decisions
