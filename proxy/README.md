# Qwen3.8 compaction proxy

Local OpenAI-compatible context compaction on `:11500` in front of the single
Qwen3.8 runtime on `:10501`.

```bash
npm install
npm test
npm start
```

See [`../docs/proxy.md`](../docs/proxy.md) and `config.yaml`. The proxy never
starts or selects a model; every model-bearing request uses `qwen3.8-local`.
