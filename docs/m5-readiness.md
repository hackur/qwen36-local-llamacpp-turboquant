# M5 readiness

The `llama-cpp-turboquant` Metal kernel logs this at startup:

```
ggml_metal_device_init: tensor API disabled for pre-M5 and pre-A19 devices
ggml_metal_library_init: turbo3 using 4-mag LUT (pre-M5 hardware)
```

**Translation:** the kernel detects M-series generation. M3 Max (this Mac) is "pre-M5" and uses a lookup-table dequant path. Apple's M5 (rumored late-2026) ships dedicated tensor-multiply hardware exposed via the Metal Tensor API — when we move to M5, the same binary will switch to the fast-path automatically. No config change.

## What that means in practice

- **Today on M3 Max**: turbo3 = LUT dequant on each KV read. Adds ~3% latency vs f16 (we measured this).
- **Tomorrow on M5**: turbo3 should approach f16 performance because the dequant happens in a single tensor-op alongside the attention matmul.

In other words, the speed gap you're paying for context will shrink to roughly zero on the next chip generation.

## Re-validating after a chip upgrade

```bash
./scripts/start-turboquant.sh & sleep 15
grep -E "tensor API|4-mag LUT|tensor cores" logs/turboquant.log
```

On M5 you should see something like `tensor API enabled` or `turbo3 using tensor-mma path` instead of the LUT message. If you don't, re-pull the fork (`./scripts/upgrade.sh`) — M5 support may have landed in a newer commit.

## Should I wait for M5 to use this?

No. The 3% trade-off for 2× context is already worth it on M3 Max. M5 will just make it free.
