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
| Node.js | 22.22.3 locally; 24.19.0 declared in `.tool-versions` |
| LM Studio | `~/.lmstudio/` (do not modify) |

## Re-capture

```sh
sysctl -n machdep.cpu.brand_string
system_profiler SPHardwareDataType | grep -E "Chip|Memory|Cores"
sw_vers
```
