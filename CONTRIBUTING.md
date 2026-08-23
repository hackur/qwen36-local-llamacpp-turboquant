# Contributing

This repository is intentionally Qwen3.8-only. Changes that add another model,
fallback alias, sidecar model, or family-specific template are out of scope.

Before committing:

```bash
make preflight
make check
make proxy-test
git diff --check
```

Runtime changes must add or update a behavioral dry-run test. Performance
claims must include the exact model artifact, engine SHA, context, K/V types,
MTP mode, prompt, token cap, warm state, sample count, and median/min/max.

Benchmark suites live in `benchmarks/suites/` and validate with:

```bash
.venv/bin/python scripts/bench_suite.py validate benchmarks/suites/*.yaml
```

Do not add GitHub Actions or another hosted CI system. The authoritative gate
is local because model, Metal, memory, thermals, and projector behavior cannot
be represented by a lightweight hosted runner.
