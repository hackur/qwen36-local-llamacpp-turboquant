# System info (captured 2026-04-27)

| | |
|---|---|
| Chip | Apple M3 Max |
| Cores | 16 (12 Performance + 4 Efficiency) |
| Memory | 64 GB unified |
| OS | macOS 26.4.1 (build 25E253) |
| Xcode | `/Applications/Xcode.app/Contents/Developer` |
| cmake | 4.3.2 (`/opt/homebrew/bin/cmake`) |
| brew | `/opt/homebrew/bin/brew` |
| git | `/opt/homebrew/bin/git` |
| LM Studio | `~/.lmstudio/` (do not modify) |

## Re-capture

```sh
sysctl -n machdep.cpu.brand_string
system_profiler SPHardwareDataType | grep -E "Chip|Memory|Cores"
sw_vers
```
