# macOS model service

The Qwen3.8 model can run as a per-user macOS LaunchAgent named
`com.local.qwen3-8.turboquant`. Its plist lives at
`~/Library/LaunchAgents/com.local.qwen3-8.turboquant.plist`. The agent starts
at login and has `KeepAlive=true`, so launchd restarts it after a process exit.
It manages only the model server on `:10501`; the optional Node compaction
proxy on `:11500` is independent.

## Lifecycle ownership

The plist runs `start-turboquant.sh foreground`, which `exec`s `llama-server`
as the job's direct child (no pipeline/tee wrappers). The job's PID *is* the
server, so launchd owns its full lifecycle: SIGTERM/SIGKILL delivery, crash
restarts, and exit accounting all apply to the real process. Nothing else
stays in the process tree as the server's parent, so no shell or tool session
can be held open by the server's fds. This is the canonical way to start,
stop, and restart the model.

| Command | Effect |
| --- | --- |
| `make service-install` | First-run bootstrap: verify the vendored `llama-server` build, launcher, and plist template exist, then register, load, and wait (up to 180 s) until the `:10501` listener answers. Fails with an actionable message at the first broken step. |
| `make service-status` | Show plist registration, launchd load state, and the `:10501` listener. |
| `make service-register` | Render the plist from the checked-in template (always, so it tracks script changes) and load it. Starts the model. Refuses to load while a non-launchd server owns `:10501` (that would crash-loop on the port bind); `make stop` first. |
| `make service-stop` or `make stop` | Unload the job and stop this repository's model processes. Keep the plist, so you can start it later. |
| `make service-start` | Load the registered job again. |
| `make service-restart` | Stop and start the registered job, then wait for the `:10501` listener. |
| `make service-unregister` | Stop the job and delete the installed plist. It will no longer start at login. |

`make install-launchd` and `make uninstall-launchd` remain aliases for register
and unregister. Registration always re-renders the plist from
`configs/launchd-plist.template`, so an installed plist tracks checked-in
changes; edit the template (and re-run `make service-register`) to change the
job. To turn the service off only for this session, use `make service-stop`;
it stays off until `make service-start` or the next login.

## Recommended start / stop / restart matrix

| Server | Start | Stop | Restart | Status |
| --- | --- | --- | --- | --- |
| Model (turboquant, `:10501`) | `make service-start` (or `make start` for a non-launchd background process) | `make stop` / `make service-stop` | `make service-restart` / `make restart` | `make status` / `make info` |
| Baseline (mainline, `:10500`) | `make start-baseline` (fg) / `make restart-baseline` (bg) | `make stop` | `make restart-baseline` | `make status` |
| Compaction proxy (`:11500`) | `make proxy-start` (bg) | `make proxy-stop` | `make proxy-restart` | `make proxy-status` |
| Laya classifier (`:18000`) | `make laya-start` (launchd) | `make laya-stop` | `make laya-restart` | `make laya-status` |

Stack-level:

| Command | Effect |
| --- | --- |
| `make start-all [M=<profile>]` | Model + proxy, background (`LAYA=1` adds the classifier). |
| `make restart-all [M=<profile>]` | `make stop` first, then `make start-all`. |
| `make restart [M=<profile>]` | Restart the model profile via `scripts/restart-turboquant.sh`. The launchd-managed `qwen38` profile is the default: it stops everything, re-registers from the template, and waits for health — the job owns the server from that point. Other profiles (e.g. `crow-9b`) have no launchd template; see the script header for the manual background pattern. |

`make start` (plain) starts a background process *outside* launchd; prefer the
service for anything long-lived. Check model readiness with `make status`;
loading the job does not mean the model has finished loading.
