# Primary sources

- [Qwen3.8-27B official model card](https://huggingface.co/Qwen/Qwen3.8-27B):
  architecture, native 262K context, MTP training, vision, thinking controls,
  preserved reasoning, sampling, and YaRN guidance.
- [Qwen3.8-27B GGUF mirror](https://huggingface.co/lmstudio-community/Qwen3.8-27B-GGUF):
  Q8_0 weights and matching BF16 projector used here.
- [TurboQuant active branch](https://github.com/TheTom/llama-cpp-turboquant/tree/feature/turboquant-kv-cache):
  Apple Metal runtime and TurboQuant cache implementation.
- [Adaptive/chained MTP PR #306](https://github.com/TheTom/llama-cpp-turboquant/pull/306):
  flags, algorithm, performance data, and Metal validation.
- [Effective KV reporting PR #301](https://github.com/TheTom/llama-cpp-turboquant/pull/301):
  Qwen3.8 6:1 GQA safety rewrite from symmetric turbo cache to q8_0 K.
- [TurboQuant VRAM issue #308](https://github.com/TheTom/llama-cpp-turboquant/issues/308):
  open upgrade risk tracked before replacing known-good pins.
- [llama.cpp server documentation](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md):
  projector, image-token, metrics, agent tools, MCP, reasoning, and API flags.
- [js-yaml npm registry](https://www.npmjs.com/package/js-yaml) and
  [pino npm registry](https://www.npmjs.com/package/pino): proxy dependencies.
- [Textual](https://pypi.org/project/textual/) and
  [PyYAML](https://pypi.org/project/PyYAML/): benchmark TUI dependencies.
