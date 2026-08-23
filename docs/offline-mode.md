# Offline mode

Use `make start-offline`. It launches the same Qwen3.8 weights, projector,
native context, KV cache, MTP, reasoning, and metrics with `AGENT=0`.

The distinction is deliberate:

- full mode: built-in tools and WebUI MCP proxy enabled;
- offline mode: inference features enabled, machine-acting/network proxy
  features disabled.

Verify after startup:

```bash
make audit-offline
```

The expected result is one localhost listening socket and no established
non-loopback socket owned by llama-server. Model and projector files must
already be local; build and model download are online preparation steps.
