# Embedded MTP

Qwen3.8 contains trained multi-token-prediction heads, so speculative decoding
does not need a draft model. The accepted TurboQuant fork adds adaptive depth
and chained drafting, including local Metal validation.

The default configuration is:

```text
--spec-type draft-mtp-adaptive
--spec-draft-n-min-adaptive 3
--spec-draft-n-max 8
--spec-chain 8
--spec-draft-p-min 0.0
```

Adaptive mode begins at depth 3, climbs when complete drafts are accepted, and
backs down under miss pressure. Chained mode drafts the selected depth in one
backend decode. This lets predictable code use deeper drafts without forcing
creative prose to remain there.

Disable MTP only for diagnosis or controlled measurement:

```bash
MTP=0 make start-foreground
```

MTP uses an additional context and materially increases memory. Keep one slot
and one llama-server process. Any throughput claim must compare the same Q8_0
artifact, prompt, context, sampling, and warm state.

Source: [TurboQuant chained/adaptive MTP PR #306](https://github.com/TheTom/llama-cpp-turboquant/pull/306).
