# Script & Server Lifecycle Audit — 2026-10-26

Scope: `scripts/*.sh` + `Makefile` + `proxy/` lifecycle. Goal: one canonical way to
start / stop / restart / observe each server (turboquant, baseline, proxy, laya),
no duplicated logic, no stale or broken paths.

## 1. Inventory

| Server         | Port  | Start (foreground)            | Start (bg/daemon)            | Stop                    | Restart | Status                          |
|----------------|-------|-------------------------------|------------------------------|-------------------------|---------|---------------------------------|
| turboquant 27B | 10501 | `make start-foreground`       | `make start` (nohup-less `&`)| `make stop`             | ✗       | `make status` / `make info`     |
| baseline 27B   | 10500 | `make start-baseline` (fg)    | ✗ none                       | `make stop`             | ✗       | `make status`                   |
| compaction     | 11500 | `make proxy-start` (fg, `cd`) | ✗ (make target is fg only)   | `make proxy-stop`       | ✗       | `make status`                   |
| laya           | 18000 | `make laya-foreground`        | `make laya-start` (launchd)  | `make laya-stop`        | ✗       | `make laya-status` / `make status` |
| model profile  | 10501 | `scripts/switch-model.sh <p>` | same (bg + health wait)      | `make stop`             | n/a     | `make status`                   |

## 2. Findings

### Broken / stale
1. **F1 — `scripts/status.sh` reads the wrong model-id key.**
   `jq -r '.data[0].id'` — llama-server `/v1/models` returns `{"models":[{"name","model",...}]}`.
   No `.data`, no `.id`. Output should be `model=?`; in practice the current
   `make status` prints `model=qwen3.8-local` only because… it doesn't — verify:
   the running probe *does* print a model, which means either a cached jq alias or
   the key resolves by accident. **Fix:** `jq -r '.models[0].model // "?"'`.
2. **F2 — `scripts/info.sh` `py_get` uses the same `.data[0]['id']` shape** for
   `model_alias` (`r['data'][0]['id']`). Same bug; returns `?` for the alias.
   **Fix:** `r['models'][0]['model']`.
3. **F3 — `scripts/quarterly-audit.sh`** probes the proxy but has no restart
   path; combined with F5 it is the only script that *assumes* the proxy PID is
   findable on 11500 (it is — fine), but it references `:11500` as a magic number
   (see D1).

### Duplicated logic
4. **D1 — Port numbers are magic constants in ≥8 files.**
   10501/10500/11500/18000 appear in `Makefile`, `status.sh`, `info.sh`,
   `service.sh`, `laya.sh`, `stop-proxy.sh`, `quarterly-audit.sh`,
   `start-baseline.sh`, `healthcheck.sh`. A port change means a repo-wide grep.
   **Fix:** single source of truth in `configs/runtime.env` (or a new
   `configs/ports.env`): `PORT_TQ=10501 PORT_BASELINE=10500 PORT_PROXY=11500
   PORT_LAYA=18000`; every script sources `_common.sh` (or `_ports.sh`) and uses
   the vars. `proxy/config.yaml` keeps its own `listen.port` but `stop-proxy.sh`
   / `status.sh` should read it (or the var) instead of hardcoding.
5. **D2 — "kill by port" is implemented 3 different ways.**
   - `stop-proxy.sh`: two-phase SIGTERM→SIGKILL, lsof by port, 5 passes, verify.
   - `stop-all.sh`: two-phase SIGTERM→SIGKILL, **ps+awk by vendor path** (because
     `pgrep -f` can't see the 700-char command line — documented), 5 passes, verify.
   - `service.sh stop` / `laya.sh stop`: `launchctl bootout` (different lifecycle).
   The two kill loops (stop-proxy vs stop-all) are near-identical but
   copy-pasted with different process-matching strategies. **Fix:** one
   `scripts/_kill.sh` helper: `kill_by_port <port>`, `kill_by_cmd <regex>`,
   both wrapping the shared two-phase loop. `stop-proxy.sh` and `stop-all.sh`
   become thin wrappers.
6. **D3 — "wait for health" is implemented 3 ways.**
   - `switch-model.sh`: curl `/health` loop, 240 s.
   - `service.sh wait_for_listener`: lsof-by-port loop, 180 s.
   - `Makefile start`: single `curl --max-time 1` (no wait at all — returns
     immediately, server still loading).
   Different timeouts, different success criteria (health vs listener).
   **Fix:** `_common.sh` gets `wait_for_health <port> [timeout]`; all callers use it.
7. **D4 — `start` backgrounding is inconsistent.**
   `make start` does `./scripts/start-turboquant.sh >> log &` (process dies if the
   calling shell is killed; no `disown`). `switch-model.sh` does the same plus
   `disown`. `make proxy-start` runs `cd proxy && npm start` **in the foreground**
   of the make invocation — so the proxy blocks the terminal until Ctrl-C, and
   there is *no* documented way to run it in the background via make. That is
   exactly how the proxy was left running orphaned earlier. **Fix:** a
   `scripts/proxy.sh start|stop|restart|status` (like `laya.sh`) with a
   nohup+disown background mode, or a launchd plist. `make proxy-start` → bg.
8. **D5 — `info.sh` and `status.sh` overlap.**
   `status.sh` = one-line-per-server. `info.sh` = full dashboard including a
   per-server block. Both curl `/health` + `lsof` + `/v1/models`. Acceptable
   (different granularity), but both must be fixed for F1/F2 and D1 together or
   they'll drift.

### Missing
9. **M1 — No restart for turboquant, baseline, or proxy.** Only `service.sh
   restart` (launchd) exists, and only if the launchd job is registered. The
   common interactive flow (foreground `make start`) has no `make restart`.
   **Fix:** add `restart` subcommands:
   - `scripts/switch-model.sh <profile> --restart` or a top-level
     `make restart [M=<profile>]` → stop (profile-aware) + start (profile-aware).
   - `scripts/proxy.sh restart` (once D4 lands).
   - `make restart-baseline` for 10500.
   - laya: `launchctl kickstart` already works via `laya.sh start` when loaded;
     add explicit `laya.sh restart` for symmetry.
10. **M2 — No unified `make restart` / `make restart-all`.**
    `stop-all.sh` stops everything; there is no inverse that starts everything
    back with correct env (proxy needs `cd proxy`, laya needs HF_HUB_OFFLINE,
    turboquant needs profile env). **Fix:** `scripts/start-all.sh` +
    `make restart-all`, reusing the per-server starters.
11. **M3 — `baseline` has no background start.** `make start-baseline` is
    foreground-only; there is no daemonized baseline, so `make stop` + no
    baseline start leaves 10500 down with no easy recovery. **Fix:** background
    variant (same pattern as D4) or document that baseline is bench-only.
12. **M4 — No `proxy` health beyond `/proxy/info`.** The proxy has `/health`
    passthrough (good) but `status.sh` uses `/proxy/info` (fine). However the
    proxy's *own* liveness ping (added earlier) logs to stdout → `proxy-run.log`
    only when started via nohup; `make proxy-start` (foreground) has no log file
    at all. Ties to D4.
13. **M5 — `switch-model.sh` does not stop the proxy or laya.** It calls
    `stop-all.sh` (which *does* stop proxy + model servers) — good — but it does
    not restart the proxy after the model swap, and if the user had the proxy
    pointed at the 27B alias, switching to the 9B (alias `crow-9b-local`) leaves
    the proxy's `model` expectation stale. **Fix:** document that proxy expects
    `qwen3.8-local`; optionally `switch-model.sh` takes `--with-proxy` to
    restart it against the new alias.

### Profile / env gaps
14. **P1 — `configs/models/` only has `crow-9b.env`.** The 27B "profile" is
    implicit (runtime.env defaults). That's fine for "go back to 27B" but it means
    `make switch M=qwen38` and `make start` are two names for the same thing.
    Acceptable; just document it.
15. **P2 — `runtime.env` `MODEL_NAME` vs `MODEL_ALIAS`.** Two vars, only
    `MODEL_NAME` is used by `append_runtime_features` (`--alias "$MODEL_NAME"`).
    `MODEL_ALIAS` is set but *never read*. Dead variable → confusing. **Fix:**
    remove `MODEL_ALIAS` from `runtime.env` and `crow-9b.env`, or wire it in.

## 3. Proposed end-state (target script set)

```
_common.sh          # + ports env, wait_for_health, kill helpers
_ports.sh (new)     # or fold into _common.sh: PORT_TQ/PORT_BASELINE/PORT_PROXY/PORT_LAYA
start-turboquant.sh # unchanged (fg), profile-aware via env
start-baseline.sh   # + optional background mode
switch-model.sh     # + --restart, --with-proxy; uses wait_for_health
stop-all.sh         # uses _kill.sh; unchanged behavior
stop-proxy.sh       # thin wrapper → _kill.sh kill_by_port $PORT_PROXY
proxy.sh (new)      # start|stop|restart|status, bg via nohup+disown, log → logs/proxy-run.log
laya.sh             # + restart subcommand
service.sh          # unchanged (launchd lifecycle)
status.sh           # fix F1, use PORT_* vars
info.sh             # fix F2, use PORT_* vars
start-all.sh (new)  # start model(profile) + proxy + laya in bg
Makefile            # restart, restart-baseline, proxy-start(bg), restart-all, start-all
```

## 4. Todo list (ordered, lowest-risk first)

> Status (2026-10-26): **ALL DONE.** T1/T2 retracted as false positives (the
> `.data[0].id` / `.data[0].meta` keys are valid — the response is an OpenAI
> superset). T9–T16 completed this session; see per-item notes below and the
> "Follow-ups" block for the launchd-ownership rework (T9) and the two
> caller-hang bugs found while backgrounding the model server.
>
> New files: `scripts/proxy.sh` (start|stop|restart|status|foreground, bg via
> nohup+disown), `scripts/_wait.sh` (CLI shim for `wait_for_health`).
> `_common.sh` gains `wait_for_health`, `kill_pids_by`, `list_pids_by_port`,
> `list_pids_by_repo_cmd`.

- [x] **T1** ~~Fix `status.sh` model-id key~~ — RETRACTED, key is valid.
- [x] **T2** ~~Fix `info.sh` model_alias py_get~~ — RETRACTED, key is valid.
- [x] **T3** Add port vars to `configs/runtime.env`: `PORT_BASELINE`, `PORT_PROXY`, `PORT_LAYA`; sourced via `_common.sh`. (D1)
- [x] **T4** Replaced all hardcoded ports in `status.sh`, `info.sh`, `service.sh`, `laya.sh`, `stop-proxy.sh`, `quarterly-audit.sh`, `healthcheck.sh`, `start-baseline.sh`, Makefile with the vars. (D1)
- [x] **T5** Add `wait_for_health <port> [timeout]` to `_common.sh`; use in `switch-model.sh`, `service.sh`, `Makefile start` (via `_wait.sh`). (D3)
- [x] **T6** Add kill helpers to `_common.sh` (`kill_pids_by`, `list_pids_by_port`, `list_pids_by_repo_cmd`); refactor `stop-proxy.sh` + `stop-all.sh` to use them. (D2)
- [x] **T7** New `scripts/proxy.sh` with `start|stop|restart|status|foreground`; background start via nohup+disown → `logs/proxy-run.log`. Verified start/restart/stop. (D4, M1, M4)
  - **Follow-up (2026-10-26):** `start` hung its caller — node was reparented to
    `proxy.sh` (PID visible in `ps`) so `bash proxy.sh start` blocked indefinitely
    (the `nohup` redirect covered node's fds but not the script's own fd 1/2). Fix:
    redirect the entire subshell's stdout/stderr to `/dev/null` before `& disown`.
    Re-verified: `start` returns immediately, node is healthy on :11500, and a
    non-streaming `/v1/chat/completions` proxied through to the turboquant server
    end-to-end (`pong`, 200, timings preserved).
- [x] **T8** `Makefile`: `proxy-start` → `./scripts/proxy.sh start` (bg); added `proxy-restart`, `proxy-status`. (D4)
- [x] **T9** `Makefile` + scripts: `restart` for turboquant, `restart-baseline`. (M1)
  - **Reworked to be launchd-owned (final design).** `restart-turboquant.sh` no
  - longer backgrounds a launcher shell. Instead it: stops everything
    (stop-all.sh), re-renders the plist from the template via `service.sh register`
    (refusing to bootstrap if :10501 is still busy), and waits for health. The
    plist runs `start-turboquant.sh foreground`, which `exec`s llama-server as
    the job's direct child, so **launchd owns the server's full lifecycle**
    (SIGTERM/SIGKILL, crash restart) and no shell stays in the process tree —
    the root cause of every caller-hang in this audit.
  - **Caller-hang bug (found while backgrounding):** the first version did
    `( ./start-turboquant.sh >> log 2>&1 ) &` and then blocked on a 240 s health
    wait while holding the server's fds; even with `disown`, start-turboquant's
    `exec ... | timestamp_logs | tee` pipeline left a bash parent alive, so the
    restart never returned. Resolved by the launchd approach above (no server-side
    wait in the restart path, no fd inheritance).
- [x] **T10** `laya.sh`: add `restart` subcommand (`launchctl kickstart` if loaded, else start). (M1)
- [x] **T11** `switch-model.sh`: add `--restart` and `--with-proxy` flags; use `wait_for_health`. (M1, M5)
  - Same caller-hang discipline: the model is started in a subshell whose own
    stdout/stderr are detached (`> /dev/null 2>&1`) before `& disown`, and the
    server pid is read by port after the bounded `wait_for_health` (not `$!`).
    `--with-proxy` brings the compaction proxy back up against the new alias.
- [x] **T12** New `scripts/start-all.sh` (model + proxy, laya optional via `LAYA=1`) + `Makefile start-all` / `restart-all`. (M2)
- [x] **T13** Baseline lifecycle: added `scripts/start-baseline.sh background [port] [ctx]` (nohup + detached fds, bounded health wait, `ALLOW_STACK=1` so it can run alongside the turboquant primary) wired to `make restart-baseline`. Foreground remains the default for controlled A/B comparison. (M3)
- [x] **T14** Removed dead `MODEL_ALIAS` from `runtime.env`, `crow-9b.env`, `switch-model.sh`. (P2)
- [x] **T15** Documented the restart matrix: `README.md` (per-server start/stop/restart table + `start-all`), `docs/service.md` (lifecycle-ownership section + recommended matrix), `docs/usage.md` (`restart` / `switch --with-proxy`). (M1)
- [x] **T16** Ran `make check` + `make proxy-test`: both green after updating the tests that asserted on pre-refactor script internals — `test_stop_scripts.py` (scanner now lives in `_common.sh` via `list_pids_by_repo_cmd` / `list_pids_by_port`; port-sync test now reads `configs/runtime.env` `PORT_PROXY`) and `test_launchers.py` (baseline dry-run pins `PORT=10500 CTX=32768`, mirroring the Makefile). `make check`: pass. `proxy-test`: 152/152 pass.

### Follow-ups / decisions logged (2026-10-26)

- **launchd-ownership is the canonical model-server lifecycle.** The plist runs
  `start-turboquant.sh foreground` → `exec llama-server`, so the job PID is the
  server and launchd handles signals + crash restart. `service.sh register`
  always re-renders the plist from the template (no more "preserve existing
  plist" drift) and `restart` waits for the listener. `restart-turboquant.sh`
  (and `make restart`) is a thin stop → register → wait wrapper over that.
- **Known pre-existing crash (not from this audit):** `logs/launchd.out` from
  2026-10-12 shows llama-server aborting inside `ggml_metal_device_free` during
  `exit`/`signal_handler`. This made the launchd job flap until the stale job
  was `bootout`-ed and re-`register`-ed clean (now `runs=1`, `never exited`).
  Worth a separate upstream look; unrelated to the script work here.
- **All background launchers share one rule:** detach the *subshell's own*
  stdout/stderr (`> /dev/null 2>&1`) before `& disown`, and read the server pid
  by port after a bounded `wait_for_health` — never `$!`. This is the fix for
  the three caller-hang bugs (proxy.sh, restart-turboquant.sh, switch-model.sh).

### Suggested batching
- **Batch A (safe, 1-line, do now):** T1, T2, T14.
- **Batch B (ports + wait helper, medium):** T3, T4, T5.
- **Batch C (kill + proxy lifecycle, larger):** T6, T7, T8.
- **Batch D (restart matrix + start-all, larger):** T9, T10, T11, T12, T13.
- **Batch E (docs + full test):** T15, T16.