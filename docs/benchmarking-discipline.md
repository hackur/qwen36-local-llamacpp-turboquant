# Benchmarking

All comparisons use the same `Qwen3.8-27B-Q8_0.gguf`. A result is invalid if
weights, quant, prompt, sampling, output cap, context, or warm state differ.

## Interactive suite

```bash
make bench-venv
make bench-tui
```

The TUI creates `benchmarks/runs/<run-id>/`, launches `bench_runner.py`, tails
`events.jsonl`, writes controls to `control.jsonl`, and leaves `runner.log`, raw
per-job JSON, and `summary.json`. Closing the TUI does not kill the detached
runner.

The runner enforces a single active benchmark process and requires only one of
the A/B ports to be listening at a time. Follow the comments in
`benchmarks/suites/qwen38-features.yaml` to switch configurations. This avoids
double-loading a 27B model and turning a benchmark into a thermal-throttle test.

## Required result metadata

- weight filename and quant;
- TurboQuant/mainline SHA;
- context and effective K/V types;
- MTP type, floor, ceiling, chain depth, and probability floor;
- prompt, output cap, thinking mode, and sampling;
- cold/warm state and sample count;
- median, minimum, and maximum tok/s;
- memory/RSS and hardware.

Use N≥5 and report medians. A one-prompt health check proves execution, not
performance.
