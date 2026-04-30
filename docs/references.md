# References

## Source of truth

- **Video** — _Ultimate Guide Local AI Setup (Qwen3.6 + LlamaC++ + TurboQuant)_
  YouTube ID: `5jkAlqbk66A`

## Repos used

- [`TheTom/llama-cpp-turboquant`](https://github.com/TheTom/llama-cpp-turboquant) — the active TurboQuant fork. **Branch:** `feature/turboquant-kv-cache`. Master has no TurboQuant.
- [`ggml-org/llama.cpp`](https://github.com/ggml-org/llama.cpp) — upstream control build.
- [`atomicmilkshake/llama-cpp-turboquant`](https://github.com/atomicmilkshake/llama-cpp-turboquant) — alternate fork. Adds TriAttention KV pruning on top of TurboQuant. Useful read for flag semantics; not used here.

## Reference setups

- [`iflow-mcp/jamesarslan-local-ai-coding-setup`](https://github.com/iflow-mcp/jamesarslan-local-ai-coding-setup) — RTX 5090 reference setup with OpenCode + Context7 + Chrome DevTools MCP. CUDA only, but the OpenCode config and sampling parameters carry over.
- [HF Space: llama-cpp-turboquant guide](https://huggingface.co/spaces/ai-engineering-at/llama-cpp-turboquant-guide) — Docker-based RTX 3090/4070 reference; documents the 5 common build pitfalls.

## Papers / docs

- TurboQuant — _Compressing the KV-Cache to 2–4 bits with Layer-Adaptive Quantization_, ICLR 2026 — [arXiv:2504.19874](https://arxiv.org/abs/2504.19874)
- [Unsloth Qwen 3.6 docs](https://unsloth.ai/docs/models/qwen3.6) — quant choices, hardware sizing
- [Qwen llama.cpp guide](https://qwen.readthedocs.io/en/latest/run_locally/llama.cpp.html) — official sampling params: `temp 0.6 top_p 0.95 top_k 20 min_p 0.0`

## Models

- [`lmstudio-community/Qwen3.6-35B-A3B-GGUF`](https://huggingface.co/lmstudio-community/Qwen3.6-35B-A3B-GGUF)
- [`unsloth/Qwen3.6-27B-GGUF`](https://huggingface.co/unsloth/Qwen3.6-27B-GGUF)

Both are mirrored in `~/.lmstudio/models/`.
