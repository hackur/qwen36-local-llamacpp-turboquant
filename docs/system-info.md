# System info (captured 2026-08-23)

| | |
|---|---|
| Chip | Apple M3 Max |
| Cores | 16 (12 Performance + 4 Efficiency) |
| Memory | 64 GB unified |
| OS | macOS 26.6.1 (build 25G76) |
| Xcode | `/Applications/Xcode.app/Contents/Developer` |
| cmake | 4.4.2 (`/opt/homebrew/bin/cmake`) |
| brew | `/opt/homebrew/bin/brew` |
| git | 2.55.0 (`/opt/homebrew/bin/git`) |
| Node.js | 22.22.3 observed on 2026-09-25; 25.9.0 declared in `.tool-versions` |
| LM Studio | `~/.lmstudio/` (do not modify) |

## Runtime observed 2026-09-25

The local TurboQuant server answered `GET /health` on `:10501` and reported
`n_ctx=98304` from `GET /props`; its process arguments included `--agent`.
`GET /tools` listed the eight built-in tools and no external MCP tools. There
was no listener on the optional Node proxy port `:11500`. These are observations
of the running session, not changes to the checked-in `CTX=262144` default.
No Laya-compatible classifier listener was found on the example `:8000` port.

## Re-capture

```sh
sysctl -n machdep.cpu.brand_string
system_profiler SPHardwareDataType | grep -E "Chip|Memory|Cores"
sw_vers
```
