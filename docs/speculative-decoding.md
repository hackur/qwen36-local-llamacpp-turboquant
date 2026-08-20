# Speculative decoding

## What it is, in 30 seconds

Speculative decoding pairs a large **target** model with a small **draft**
model that shares the same tokenizer. The draft proposes N candidate tokens
cheaply; the target then verifies all N in a single batched forward pass,
keeping the longest accepted prefix and discarding the rest. When acceptance
is high, the target produces several tokens per forward — its
memory-bandwidth cost amortizes across them — without changing what the
target itself would have generated.

## Default path: Qwen3.8 embedded MTP

Qwen3.8 already contains its own multi-token-prediction draft head, so the primary launcher needs no second model:

```bash
make start
# equivalent flags:
# --spec-type draft-mtp --spec-draft-n-max 3 --spec-draft-p-min 0.5
```

This is enabled automatically for `qwen38-27b`. On the M3 Max it measured 24.60 tok/s versus 11.90 tok/s with `MTP=0`. Disable it only for an A/B test: `MTP=0 make start`. Vision keeps MTP off by default because that combined path has less production mileage than text-only MTP.

## Built-in draft alias

The simplest path: use the `qwen3.5-0.8b` alias that ships with the repo (Qwen
3.5 0.8B Q8_0, ~775 MB, same Qwen3 tokenizer family as `qwen36-neo` /
`qwen36-35b`). After `./scripts/symlink-models.sh` picks it up, point the
harness at it via `models/draft.gguf`:

```bash
ln -sf "$HOME/.lmstudio/models/unsloth/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q8_0.gguf" \
       models/draft.gguf
DRAFT=models/draft.gguf ./scripts/test-spec-decode.sh
# or pass the alias directly:
DRAFT=qwen3.5-0.8b ./scripts/test-spec-decode.sh
```

## Alternative drafts — acquiring a Qwen3-0.6B GGUF (offline-first; do NOT auto-download)

This repo is offline-first by design. To add a draft model:

1. On a machine with internet, fetch a Qwen3-0.6B GGUF that shares the
   Qwen3 tokenizer used by `qwen36-neo` / `qwen36-35b`. Candidate sources
   (placeholders — verify SHA256 against the model card before using):

   - `https://huggingface.co/Qwen/Qwen3-0.6B-GGUF`
   - `https://huggingface.co/unsloth/Qwen3-0.6B-GGUF`
   - LM Studio: search `Qwen3-0.6B`, prefer Q8_0 or Q5_K_M (the draft is
     small enough that going below Q5 buys little memory and costs accuracy,
     which lowers the acceptance rate).

2. Move the `.gguf` into LM Studio's cache (so `scripts/symlink-models.sh`
   can pick it up) **or** drop it directly under this repo's `models/`.

## Where to symlink it

The simplest layout — one symlink, no edits to `symlink-models.sh`:

```bash
ln -sf "$HOME/.lmstudio/models/Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf" \
       models/draft.gguf
```

Then `DRAFT=models/draft.gguf ./scripts/test-spec-decode.sh` works.

Optional alias path: add a `qwen3-0.6b-draft` row to `MODELS=( … )` in
`scripts/symlink-models.sh`, re-run it, and pass `DRAFT=qwen3-0.6b-draft`
(the script also resolves bare aliases under `models/<alias>.gguf`).

## When it helps

Long generations on memory-bandwidth-bound models. `qwen36-neo` decoding at
~14 tok/s sustained @ 128K (see `benchmarks/RESULTS.md`) is bandwidth-bound:
each token is a full pass over 19.5 GB of weights. If the 0.6B draft can
propose tokens cheaply and the target accepts most of them, the per-token
cost falls toward `weights_pass / accepted_tokens`. The win is largest on
predictable, low-entropy generation: code, structured JSON, repetitive
prose. Greedy / low-temperature settings raise acceptance.

## When it doesn't

Short prompts where prefill dominates wall-clock; speculative decoding only
speeds up the **decode** loop, not prefill. Models that already decode fast
because they're MoE with few active params (e.g. `qwen36-35b` at ~63 tok/s
on this hardware) — the verifier overhead and the draft's own forward cost
can outweigh the savings. High-temperature sampling, since acceptance falls
when the target's distribution is wide. And anything the draft can't
predict well: long-tail factual recall, fresh code with novel identifiers.

## Tunables

- `--draft N` (alias `--draft-max`, default 16): max tokens the draft
  proposes before each verify. We default the harness to 8 — a conservative
  starting point. Sweep 4 / 8 / 16 / 32 to find the optimum for your
  workload; longer drafts win when acceptance is high but waste compute
  when it isn't.
- `--draft-min N`: minimum draft length before we bother batching. Useful
  to avoid pathological short-batch cases.
- `--draft-p-min P` (default 0.75): minimum greedy probability under which
  the draft stops proposing further tokens. Lower → longer drafts, lower
  acceptance.
- `-cd / --ctx-size-draft`: leave at 0 (= same as target) unless you're
  memory-pinned on the draft.
- `-ctkd / -ctvd`: KV cache type for the draft. The draft is small — f16
  is fine and removes one variable from the comparison.

## Quickstart

```bash
# 1. Symlink a draft GGUF (one-time):
ln -sf "$HOME/.lmstudio/models/Qwen/Qwen3-0.6B-GGUF/Qwen3-0.6B-Q8_0.gguf" \
       models/draft.gguf

# 2. Run the harness (target = qwen36-neo, default port 10596):
MODEL=qwen36-neo DRAFT=models/draft.gguf DRAFT_TOKENS=8 \
    ./scripts/test-spec-decode.sh

# 3. Compare the spec-decode-<ts>.md report against the qwen36-neo entry
#    in benchmarks/RESULTS.md (2026-05-07).
```

The harness brackets the run with `scripts/diagnose-variance.sh`
(pre/post snapshots in `logs/variance-spec-{pre,post}-*.log`) and idle
cooldowns. It refuses to start if the binary lacks `--model-draft` — in
which case rebuild from a recent mainline merge (see
`docs/upstream-tracking.md`).

## Pitfalls

**Tokenizer mismatch is the failure mode.** If the draft and target encode
the same string to different token IDs, llama.cpp won't error — but the
draft's proposals will fail verification almost every time, the acceptance
rate collapses, and you get a *silent* throughput regression (and, if your
sampler isn't strict, subtle quality drift on rare tokens). Always pair a
target with a draft from the same tokenizer family. For the Qwen3.6 27B /
35B models in this repo, that means a Qwen3 (or Qwen3.6) draft — Qwen2.5,
Llama, Gemma, Mistral are all wrong.

Quick vocab-size sanity check, against a running spec-decode server:

```bash
# Both should print the same vocab_size.
curl -s http://127.0.0.1:10596/props \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); \
                m=d.get("default_generation_settings",{}).get("model"); \
                print("model:",m,"vocab:",d.get("vocab_size"))'
```

For a tighter check, tokenize a string with control characters / CJK / emoji
and verify both models produce the same IDs (the draft must be loaded as a
separate server on another port for this; the spec-decode server only
exposes the target's tokenizer over `/tokenize`).

Other gotchas:

- The draft must fit in VRAM **alongside** the target. Qwen3-0.6B Q8_0 is
  ~700 MB — fine on 64 GB, but watch the memory pre-flight if you also run
  vision (`scripts/start-vision.sh`).
- Draft and target must agree on `--ctx-size`. The harness inherits the
  target's CTX and lets the draft default to 0 (= same).
- `--np` must stay at 1 (it already is in `_common.sh::COMMON`). Spec
  decoding with parallel slots is a different code path.

## See also

- [`docs/usage.md`](usage.md) — performance tips and per-model recipes.
- [`benchmarks/RESULTS.md`](../benchmarks/RESULTS.md) — baselines to
  compare a spec-decode run against.
- [`docs/upstream-tracking.md`](upstream-tracking.md) — when the
  TurboQuant fork last merged mainline (where `--model-draft` lives).
