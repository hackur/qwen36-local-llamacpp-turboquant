# Qwen3.8 compaction proxy

Local OpenAI-compatible context compaction on `:11500` in front of the single
Qwen3.8 runtime on `:10501`. This service is optional and starts separately
from `make start`. Its checked-in mode is `shadow`, with local Laya classification.

```bash
npm install
npm test
npm start
```

See [`../docs/proxy.md`](../docs/proxy.md) and `config.yaml`. The proxy never
starts or selects a model; every model-bearing request uses `qwen3.8-local`.
Clients using `:10501` directly do not traverse this proxy.

JEV/Laya classification uses the local typed-decisions checkpoint on `:18000`.
Run `make laya-start` from the repository root. See [Laya setup](../docs/laya.md)
and the [proxy guide](../docs/proxy.md) for modes,
classifier behavior, and the standalone research script.
