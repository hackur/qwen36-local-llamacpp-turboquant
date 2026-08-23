# Qwen3.8 validation results

Only results produced with Qwen3.8-27B Q8_0 belong here. Older model results
remain available through tagged git history.

## 2026-08-20 acceptance smoke

- weights: `Qwen3.8-27B-Q8_0.gguf`
- projector: `mmproj-Qwen3.8-27B-BF16.gguf`
- TurboQuant: `bd1bf025fc55ffa1fcb2ba6d8bb8805f35671d1f`
- llama.cpp: `681c29d36a13be54d317ee147b272da9163dbef3`
- hardware: Apple M3 Max, 64 GiB unified memory
- context: 262,144 native tokens
- effective KV: q8_0 K / turbo3 V
- MTP: fixed depth 3, `p_min=0.5`

The full-context server loaded, generated a short response at 21.53 tok/s,
and reported 6/6 accepted draft tokens. The unified projector path identified
the generated vision fixture and generated at 12.07 tok/s. These are smoke
observations, not controlled performance claims.

## Pending controlled result

Run `make bench-tui` on a cool chassis and record N=5 median/min/max for the
adaptive chained configuration versus the same artifact with `MTP=0`.

## 2026-08-23 upstream-tip diagnostic

Before accepting the 2026-08-23 TurboQuant tip, the current and prior pins were
built locally and exercised with the same Qwen3.8 artifact, 262,144-token
runtime, q8_0/turbo3 KV, adaptive chained MTP (3-8, chain 8), non-thinking
sampling, and three 500-token generations.

| TurboQuant revision | Runs (tok/s) | Mean | Median |
|---|---:|---:|---:|
| `cfd7bde3f` candidate | 7.01, 7.67, 6.15 | 6.94 | 7.01 |
| `bd1bf025f` prior control | 7.42, 6.07, 7.02 | 6.84 | 7.02 |

The difference is noise-level; the candidate did not reproduce a throughput
regression on this host. This N=3 diagnostic is an upgrade guard, not the
pending cool-chassis N=5 MTP-on/off result. The full candidate also loaded the
native 262K context, exposed eight built-in tools, populated metrics, invoked a
read-only tool, and passed the vision smoke.

The same accepted build recovered `fjord-mango-pinwheel-9421` from the routine
50K needle probe (44,486 actual prompt tokens): 92.3 prompt tok/s, 6.5 generation
tok/s, 483.9 seconds wall time. The native 262,144-token window remained loaded
throughout. The mixed thinking/non-thinking ten-case acceptance evaluation
passed 10/10. The live proxy integration gate also passed non-streaming,
streaming, tool-call, tool-result, debug-rewrite, and compaction-bypass paths.
