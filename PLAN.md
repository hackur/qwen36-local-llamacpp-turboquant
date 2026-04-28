# Plan — Qwen 3.6 + llama.cpp + TurboQuant (offline-first, Apple Silicon)

Goal: the **fastest, most reliable** local Qwen 3.6 setup on this M3 Max that **works with the network off**. Built around the YouTube guide _Ultimate Guide Local AI Setup (Qwen3.6 + LlamaC++ + TurboQuant) [5jkAlqbk66A]_ and the public TurboQuant repos.

## Hardware/OS baseline

- Apple M3 Max, 16 cores (12P + 4E), **64 GB unified memory**
- macOS 26.4.1, Xcode CLT, cmake 4.3.2, Homebrew
- LM Studio installed at `~/.lmstudio/` (do not disturb)

## Models already on disk (no re-download)

| Path | Quant | Size | Use |
|---|---|---|---|
| `~/.lmstudio/models/lmstudio-community/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-Q6_K.gguf` | Q6_K (MoE, ~3B active) | 28.5 GB | **Primary** — best quality fast on M3 Max |
| `~/.lmstudio/models/lmstudio-community/Qwen3.6-35B-A3B-GGUF/mmproj-Qwen3.6-35B-A3B-BF16.gguf` | BF16 vision proj | 0.9 GB | Multimodal |
| `~/.lmstudio/models/unsloth/Qwen3.6-27B-GGUF/Qwen3.6-27B-UD-IQ2_XXS.gguf` | IQ2_XXS | 9.4 GB | Low-mem fallback |
| `~/.lmstudio/models/unsloth/Qwen3.6-27B-GGUF/mmproj-F32.gguf` | F32 vision proj | 1.8 GB | Multimodal fallback |

## Stack

```
GGUF on disk
  └─ llama.cpp (Metal)         ── A: mainline build, f16 KV cache (control)
  └─ llama-cpp-turboquant      ── B: TurboQuant build, -ctk turbo3 -ctv turbo3
        feature/turboquant-kv-cache branch
              │
              ▼
       llama-server  (OpenAI-compatible)
              │
              ▼
   curl / python-openai / web UI / OpenCode / Continue
```

Two servers, two ports, A/B benchmarked head-to-head:

| Profile | Binary | Port | KV cache | Context |
|---|---|---|---|---|
| baseline | `vendor/llama.cpp-mainline/build/bin/llama-server` | 10500 | f16 | 32K |
| turboquant | `vendor/llama-cpp-turboquant/build/bin/llama-server` | 10501 | turbo3 | 128K |
| fallback (if turbo3 not on Metal) | mainline binary | 10502 | q8_0 | 64K |

## Critical caveat — Metal

TurboQuant's public benchmarks and Dockerfile are CUDA-only. The fork claims Apple Silicon is "first-class via NEON/Accelerate/Metal", but `-ctk turbo3` is unverified on Metal. The plan has a **fallback to standard q8_0 KV-cache quantization**, which is fully supported on Metal and still gives a large context win, in case the turbo3 kernel falls back to CPU or errors out.

## 41-task checklist

### Repo & docs
- [ ] 1. Initialize repo structure & git
- [ ] 2. Document hardware & OS baseline → `docs/system-info.md`
- [ ] 3. Inventory existing Qwen 3.6 GGUFs → `docs/models.md`
- [ ] 4. Pick primary model (35B-A3B Q6_K) — decision recorded
- [ ] 5. Write `docs/architecture.md`
- [ ] 30. Add `.gitignore` (vendor/, logs/, *.gguf, .DS_Store)
- [ ] 38. Write top-level `README.md`
- [ ] 39. Persist this plan as `PLAN.md` ← in progress
- [ ] 40. `docs/references.md` — video + repos + paper

### Build
- [ ] 6. Clone `ggml-org/llama.cpp` → `vendor/llama.cpp-mainline`
- [ ] 7. Build mainline with `-DGGML_METAL=ON -DGGML_NATIVE=ON`
- [ ] 8. Clone `TheTom/llama-cpp-turboquant` branch `feature/turboquant-kv-cache` → `vendor/llama-cpp-turboquant`
- [ ] 9. Build TurboQuant fork with same Metal flags
- [ ] 10. `llama-server -h | grep -E 'turbo[234]'` → verify flags compiled in
- [ ] 11. Write `docs/metal-compatibility.md` documenting outcome
- [ ] 12. `scripts/build-llama.sh` (idempotent, builds both forks)

### Run
- [ ] 13. `scripts/start-baseline.sh` (port 10500, f16 KV, 32K ctx)
- [ ] 14. `scripts/start-turboquant.sh` (port 10501, turbo3 KV, 128K ctx)
- [ ] 15. `scripts/start-fallback.sh` (port 10502, q8_0 KV, 64K ctx)
- [ ] 16. Port-conflict guard vs LM Studio (`lsof -i :10500`)
- [ ] 17. `configs/qwen3.6-sampling.json` — temp 0.6, top_p 0.95, top_k 20, min_p 0
- [ ] 18. `scripts/healthcheck.sh` — /v1/models + small completion
- [ ] 27. `configs/launchd-plist.template` for auto-start at login
- [ ] 32. Decide symlink strategy so models stay shared with LM Studio

### Demo / clients (the user-facing piece)
- [ ] 23. `scripts/demo-chat.sh` (curl + jq streaming TUI)
- [ ] 24. `clients/python-demo.py` (openai-python pointing at localhost)
- [ ] 25. `clients/web-demo.html` (single-file streaming UI w/ tok/s)
- [ ] 26. `docs/multimodal.md` (mmproj usage)
- [ ] 28. `configs/opencode.json` + `configs/continue.json`

### Benchmark
- [ ] 19. `scripts/benchmark.sh` (warmup + 3× 400-word gen, A/B)
- [ ] 20. `scripts/long-context-test.sh` (100K needle-in-haystack)
- [ ] 21. `scripts/monitor-mem.sh` (memory_pressure CSV)
- [ ] 31. Compare custom server vs LM Studio's runtime
- [ ] 33. `docs/context-matrix.md` — max -c per KV-cache type
- [ ] 34. Run baseline benchmark → `benchmarks/baseline.json`
- [ ] 35. Run TurboQuant benchmark → `benchmarks/turboquant.json`
- [ ] 37. `scripts/quality-check.sh` (5 fixed prompts, diff outputs)
- [ ] 36. Write `benchmarks/RESULTS.md`

### Offline & resilience (the actual goal)
- [ ] 22. `docs/offline-validation.md` — procedure
- [ ] 29. `docs/troubleshooting.md` — top 5 errors + Metal-specific
- [ ] 41. **Final**: re-run demo with Wi-Fi off, log results

## Quickstart (target)

```bash
./scripts/build-llama.sh          # ~5 min on M3 Max, builds both forks
./scripts/start-baseline.sh &     # port 10500
./scripts/start-turboquant.sh &   # port 10501
./scripts/healthcheck.sh
./scripts/demo-chat.sh            # talk to your offline brain
./scripts/benchmark.sh            # numbers
```

## Decision log

- **35B-A3B over 27B**: A3B is a 35B-param MoE with only ~3B active per token — it's faster *and* smarter than the 27B dense variant on this hardware. 27B IQ2_XXS stays around as the low-memory fallback.
- **Q6_K over Q4_K_M**: 64 GB lets us afford Q6_K's quality margin without paging.
- **Two binaries, not one**: keeps a known-good mainline build as the control whenever the turboquant fork breaks against new GGUF formats.
- **Port 10500/10501**, not 1234, to coexist with LM Studio.
- **Symlink, don't copy**: 28 GB × 2 wastes the SSD.

## References

- YouTube: _Ultimate Guide Local AI Setup (Qwen3.6 + LlamaC++ + TurboQuant)_ — `5jkAlqbk66A`
- TurboQuant fork (Metal-capable claim): https://github.com/TheTom/llama-cpp-turboquant — branch `feature/turboquant-kv-cache`
- Alt fork w/ TriAttention: https://github.com/atomicmilkshake/llama-cpp-turboquant
- Reference setup (CUDA): https://github.com/iflow-mcp/jamesarslan-local-ai-coding-setup
- HF guide: https://huggingface.co/spaces/ai-engineering-at/llama-cpp-turboquant-guide
- Paper: TurboQuant, ICLR 2026, arXiv:2504.19874
- Unsloth Qwen 3.6 docs: https://unsloth.ai/docs/models/qwen3.6
