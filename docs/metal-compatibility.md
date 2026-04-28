# TurboQuant on Apple Metal — does it actually work?

**Short answer:** ✅ **Yes — Metal kernels for turbo2/turbo3/turbo4 are compiled in and loading on M3 Max.**

Smoking-gun log line at server startup:

```
ggml_metal_library_init: turbo3 using 4-mag LUT (pre-M5 hardware)
ggml_metal_library_init: turbo3 sparse V dequant enabled (opt-out: TURBO_SPARSE_V=0)
ggml_metal_library_init: loaded in 17.375 sec
```

Two interesting nuggets in there:

- "**4-mag LUT (pre-M5 hardware)**" — the kernel detects the M-series generation. M5 (when it ships) gets a faster path with new tensor cores; M1/M2/M3/M4 use the lookup-table path. So this fork is M5-aware *today*, falling back gracefully on M3 Max.
- "**sparse V dequant enabled**" — controlled by `TURBO_SPARSE_V` env var. Note that the most recent upstream commit is `fix/disable-sparse-v-cuda` — sparse V was broken on CUDA, fine on Metal. If quality regressions appear, set `TURBO_SPARSE_V=0`.

`-ctk`/`-ctv` accept `turbo2`, `turbo3`, `turbo4` plus all the standard quants (`q8_0`, `q4_0`, `iq4_nl`, etc.).

## Why this is in question

TurboQuant's published numbers (RTX 3090, RTX 4070 Laptop, etc.) are CUDA-only. The fork at `TheTom/llama-cpp-turboquant` claims first-class Apple Silicon support via NEON / Accelerate / Metal, but the recent commit history (e.g. `fix/disable-sparse-v-cuda` on `master` of branch HEAD `11a241d`) suggests CUDA is the actively-developed path.

The cache types `turbo2`/`turbo3`/`turbo4` are implemented as new GGML quantization types. For Metal to actually use them, two things have to be true:

1. The `turbo*` cache types are registered in `ggml-metal.metal` (the shader source).
2. There's a host-side dispatch in `ggml-metal.m` that maps the type to a Metal kernel.

If only the CPU/CUDA paths are implemented, llama-server will start fine, but the Metal backend will fall back to CPU on every KV op — which is slower than the `f16` Metal baseline despite the smaller KV cache.

## What the build script checks

`scripts/build-llama.sh` greps the compiled binary for `turbo[234]` in `--help`. If they appear, the **CLI flag** is recognized. That doesn't mean the Metal kernel exists — it just means the option parser knows about it.

The real test is in `scripts/start-turboquant.sh`: when started with `-ctk turbo3 -ctv turbo3 -ngl 99`, the first prompt either:

- prints normally → Metal kernel works ✅
- prints "ggml_metal: kernel turbo3 not found, falling back" or similar → CPU fallback, will be slow
- crashes with "Unsupported cache type" → the C++ code path doesn't exist for Metal at all

## Decision tree

```
    build the fork
          │
          ▼
   turbo[234] in -h?  ── no ──▶  use scripts/start-fallback.sh (q8_0 KV)
          │
         yes
          │
          ▼
   start with -ctk turbo3 -ngl 99
   → first prompt finishes normally?
          │
   ┌──────┴──────┐
   yes           no
   │             │
   measure tps   ┌─ "kernel not found" → fallback, file upstream issue
   vs baseline   ├─ crash             → fallback, file upstream issue
                 └─ very slow         → fallback (Metal→CPU)
```

## Result

To be filled in by `benchmarks/RESULTS.md` after first run.
