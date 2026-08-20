# Context-length matrix

Current default per `scripts/_common.sh` is `MODEL_PRIMARY=qwen38-27b`
(Qwen3.8-27B Q8_0); **Qwen3.6-35B-A3B Q6_K is the fallback**. The
Qwen3.8 primary has been live-tested at its full 262,144-token context at
roughly 34.5 GiB RSS. The historical matrix below covers the 35B-A3B fallback;
for the older NEO model, see `docs/kv-cache-math.md`.

Estimated max usable `-c` for Qwen3.6-35B-A3B Q6_K on **M3 Max 64 GB**, with weights mmapped (~28.5 GB) and ~6 GB held by macOS.

Available for KV cache + scratch: **≈ 25 GB**.

Bytes/token derived from the GGUF metadata of `models/qwen36-35b.gguf` (block_count=40, head_count_kv=2, key_length=value_length=256, full_attention_interval=4 → 10 of 40 layers carry attention KV). f16 baseline = `2 × 10 × 2 × 256 × 2 = 20 480 B/tok`.

| KV cache type | Bytes/token (35B-A3B) | Max ctx (rough) | Where defined |
|---|---|---|---|
| `f16`     | ~20 KiB | **256K** (training-context bound, not memory) | `scripts/start-baseline.sh` |
| `q8_0`    | ~10.5 KiB | **256K** (training-context bound) | `scripts/start-fallback.sh` |
| `q4_0`    | ~5.5 KiB | **256K** (training-context bound; degraded recall) | `KV=q4_0 ./scripts/start-turboquant.sh` |
| `turbo3`  | ~11.6 KiB (measured @ 64K) | **256K** (training-context bound) | `scripts/start-turboquant.sh` |

For the 35B-A3B on this hardware the bottleneck is the model's `n_ctx_train = 262 144`, not KV memory: at 20 KiB/tok f16, 256K context is only ~5 GB of KV. All KV types comfortably reach the full training window (estimate — measurement pending for exact ceilings of q8_0/q4_0/turbo2 and for prefill latency at 256K). turbo3 has been verified on Metal (742 MiB measured @ 64K — see `docs/kv-cache-math.md`).

## How to read the table

The numbers assume the server started cleanly and ran at least one ~5K-token prompt without `failed to allocate` in the log. They are not theoretical maxes — they are the points where peak unified-memory usage stays under ~50 GB and the Mac doesn't start swapping. For the 35B-A3B specifically, every row hits the model's training-context cap (256K) before hitting the memory cap.

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
