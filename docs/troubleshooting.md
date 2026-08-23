# Troubleshooting

## Preflight reports a missing artifact

Run `make model-link`. It expects the exact Q8_0 weights and BF16 projector
under LM Studio or `MODELS_ROOT`. Other quant filenames are not silently used.

## Required server flag is missing

The binary predates the accepted Qwen3.8 feature set. Run `make upgrade`, then
validate the candidate before updating pins. Do not remove the guard.

## Another llama-server is running

Run `make stop`. The 27B Q8_0 model, projector, full context, and MTP context
are intentionally single-process on this 64 GiB machine. `ALLOW_STACK=1` is
reserved for controlled short comparisons on a cool chassis.

## Memory pressure or slow generation

Start with `CTX=131072 make start-foreground`. Disable MTP with `MTP=0` to
separate speculative-context memory from model/KV pressure. Check Activity
Monitor for compression and swap before attributing speed loss to the engine.

## Agent tools are unavailable

Confirm `AGENT=1` and check `/tools`. The server must advertise `--agent`; the
launcher refuses older builds. External MCP servers additionally require a
readable `MCP_CONFIG` file.

## Strict offline audit fails

Stop the server and launch `make start-offline`. Full agent mode intentionally
contains an MCP CORS proxy and is not the offline validation profile.

## Vision is inaccurate

Confirm the BF16 projector is the one from the same Qwen3.8 GGUF repository.
The launcher passes a 1024-token minimum for images. Run `make vision`; if a new
engine pin changed the result, return to the previous accepted SHA.

## Benchmark TUI waits on a port

This is deliberate. Only one A/B side may listen at a time. Follow the launch
comments in `benchmarks/suites/qwen38-features.yaml`, stop the current side,
and start the requested one.
