# Context-length matrix

Estimated max usable `-c` for Qwen3.6-35B-A3B Q6_K on **M3 Max 64 GB**, with weights mmapped (~28.5 GB) and ~6 GB held by macOS.

Available for KV cache + scratch: **≈ 25 GB**.

| KV cache type | Bytes/token (35B-A3B, est.) | Max ctx (rough) | Where defined |
|---|---|---|---|
| `f16`     | ~80 KB | **~32K** comfortable, 48K tight | `scripts/start-baseline.sh` |
| `q8_0`    | ~40 KB | **~64K** comfortable, 96K tight | `scripts/start-fallback.sh` |
| `q4_0`    | ~20 KB | ~128K (degraded recall) | `KV=q4_0 ./scripts/start-turboquant.sh` |
| `turbo3`* | ~10–15 KB | **~128–192K** target | `scripts/start-turboquant.sh` |

\* turbo3 numbers are extrapolated from the CUDA paper. Metal kernel correctness is unverified — confirm by actually running and watching the server log for "ggml_metal: kernel turbo3 not implemented" or similar warnings.

## How to read the table

The numbers assume the server started cleanly and ran at least one ~5K-token prompt without `failed to allocate` in the log. They are not theoretical maxes — they are the points where peak unified-memory usage stays under ~50 GB and the Mac doesn't start swapping.

## Re-running this calibration

```bash
for ctx in 32768 65536 98304 131072; do
  CTX=$ctx ./scripts/start-turboquant.sh > /tmp/probe-$ctx.log 2>&1 &
  PID=$!
  sleep 30
  if grep -q "failed to allocate" /tmp/probe-$ctx.log; then echo "ctx=$ctx: OOM"; else echo "ctx=$ctx: OK"; fi
  kill $PID; wait $PID 2>/dev/null
done
```
