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
