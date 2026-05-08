# qwen-compact-proxy

## What this is

A Node/Fastify reverse proxy that sits at `:11500` in front of `llama-server`
on `:10501` and compacts Claude-Code-style sessions before they hit the model.
Defaults to **off** (byte-for-byte passthrough with instrumentation). Modes:
`passthrough` / `shadow` / `enforce`. Every response carries an
`x-proxy-request-id` header matching the JSONL log line.

## Quickstart

```
cd proxy && npm install && npm test
```

From the repo root, `make proxy-start` runs it against a live turboquant
upstream. See `docs/proxy.md` for the operator quickstart and full config.

## Implemented phases

See `docs/proxy.md` and `docs/compaction-strategy.md` for details.

- **Phase 0** — instrumentation + passthrough, JSONL request logs.
- **Phase 1** — Tier-0 verbatim + Tier-1 elision + `expand_tool_result`.
- **Phase 2** — recursive summarizer (off without `summarizer.url`).
- **Phase 3** — session keying (off without `session.enabled`).
- **Phase 4 / 5** — structured notes + sumy fallback (off without
  `notes.enabled` / `sumy.enabled`).
- **Phase 6** — hook engine + 5 built-in handlers (off without
  `hooks.enabled`); spec in `docs/hooks-middleware.md`.

## Layout

`src/` holds `server.js` (Fastify entry), `rewrite.js` (tier logic),
`summarizer.js`, `session.js`, `notes.js`, `sniffUsage.js`, and
`hooks/{engine,registry,...}.js`. Config lives in `proxy/config.yaml`;
JSONL logs land under `<cache_dir>/logs/YYYY-MM-DD.jsonl`.

## Tests

`npm test` — currently 126/126 passing. Test files live under `tests/`.
`tests/integration.sh` exercises the proxy against a real `llama-server`.

## Eval / A/B harness

See `eval/ab-harness/` and `docs/hooks-middleware.md` §11 for the
shadow-vs-enforce comparison rig.

## Pointers

- `docs/proxy.md` — operator quickstart, config knobs, env overrides.
- `docs/compaction-strategy.md` — design rationale and tier model.
- `docs/hooks-middleware.md` — Phase 6 hook spec.
