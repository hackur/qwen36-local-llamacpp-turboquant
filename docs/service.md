# macOS model service

The Qwen3.8 model can run as a per-user macOS LaunchAgent named
`com.local.qwen3-8.turboquant`. Its plist lives at
`~/Library/LaunchAgents/com.local.qwen3-8.turboquant.plist`. The agent starts
at login and has `KeepAlive=true`, so launchd restarts it after a process exit.
It manages only the model server on `:10501`; the optional Node compaction
proxy on `:11500` is independent.

| Command | Effect |
| --- | --- |
| `make service-status` | Show plist registration, launchd load state, and the `:10501` listener. |
| `make service-register` | Create the plist if missing and load it. Starts the model. |
| `make service-stop` or `make stop` | Unload the job and stop this repository's model processes. Keep the plist, so you can start it later. |
| `make service-start` | Load the registered job again. |
| `make service-restart` | Stop and start the registered job. |
| `make service-unregister` | Stop the job and delete the installed plist. It will no longer start at login. |

`make install-launchd` and `make uninstall-launchd` remain aliases for register
and unregister. Registration preserves an existing plist, including local
runtime overrides. The checked-in template is used only when no installed
plist exists. To change an installed plist, edit that file explicitly, then
run `make service-restart`. To turn the service off only for this session, use
`make service-stop`; it stays off until `make service-start` or the next login.

`make start` starts a background process outside launchd. When using the
registered service, use `make service-start` instead. Check model readiness
with `make status`; loading the job does not mean the model has finished loading.
