# Qwen3.8 context compaction

The optional proxy on `127.0.0.1:11500` keeps long OpenAI-compatible agent
sessions within Qwen3.8's 262,144-token native context. It forwards to the
single full runtime on `127.0.0.1:10501`; no legacy model or summarizer sidecar
is required.

## Processing order

1. Preserve the newest turns verbatim.
2. Replace oversized historical tool results with deterministic, rehydratable
   stubs.
3. Optionally extract structured notes from older results.
4. Optionally apply an inline extractive fallback.
5. Optionally ask the direct Qwen3.8 upstream to summarize prose before the
   main request is forwarded.

The proxy defaults to `passthrough`. Use `shadow` to measure a candidate rewrite
without changing the upstream request. Use `enforce` only after replay and
needle tests preserve the facts and decisions that matter.

## Watermarks

The initial prompt watermark is 70% of the configured 262,144-token context.
That number is deliberately a starting point. `scripts/analyze-watermarks.py`
reconstructs sessions from local JSONL telemetry and compares 50%, 60%, 70%,
75%, and 80% candidates. See [watermark-tuning.md](watermark-tuning.md).

Token counts should come from the active server's `/tokenize` endpoint wherever
possible. The four-characters-per-token estimate is only a degraded fallback
for unavailable telemetry.

## Same-model summarization

When `summarizer.mode` is `shadow` or `enforce`, set `summarizer.url` to
`http://127.0.0.1:10501`. The proxy calls that direct upstream, not itself, so
the request cannot recurse through the compaction path. Qwen3.8 performs the
summary before the main request is sent. Errors and timeouts fall through to
deterministic elision; they never fail the user's request.

This choice trades concurrency for operational simplicity and memory safety:
only one model is resident, and every model-facing path uses the accepted
Qwen3.8 artifact.

## Quality gates

Before enabling `enforce` for normal work:

```bash
make proxy-test
python3 proxy/eval/replay.py --target http://127.0.0.1:11500/v1/chat/completions \
  --session proxy/eval/fixtures/needle_50turns.jsonl
python3 proxy/eval/needle.py verify --responses /path/to/responses.json
```

The committed synthetic fixture checks recall mechanics. Real decision logs
must remain private and should be replayed locally. A rewrite is acceptable only
when it preserves exact identifiers, paths, error messages, exit codes, numeric
facts, explicit decisions, and unresolved work.

## Security and limits

- Both server and proxy bind to loopback by default.
- Tool-result content is untrusted input and never controls hook registration.
- Rehydration files live under `~/.cache/qwen-compact` and are not committed.
- Compaction cannot recover facts the client omitted before the proxy saw them.
- The proxy does not replace the model's native context limit or make an
  overfilled prompt safe; it reduces context before forwarding.

The exact configuration and implemented tiers are documented in
[proxy.md](proxy.md), `proxy/config.yaml`, and
[hooks-middleware.md](hooks-middleware.md).
