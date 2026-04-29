# Usage cookbook

Concrete recipes for every model and every workflow. Pick a model below by what you want to do, then copy a recipe.

- [Picking a model](#picking-a-model)
- [Per-model recipes](#per-model-recipes)
- [Workflows](#workflows)
- [Performance tips](#performance-tips)
- [Editor integration](#editor-integration)
- [Troubleshooting recipes](#troubleshooting-recipes)

---

## Picking a model

Decide by **memory budget** first, **task** second.

| You have… | Use |
|---|---|
| 64 GB RAM, want best quality, 100K+ context | `qwen36-35b` (default) |
| 64 GB RAM, want a Gemma flavor for variety | `gemma4-26b` |
| 64 GB RAM, want OpenAI-style behavior | `gpt-oss-20b` |
| 32 GB RAM | `qwen35-9b`, `gemma4-e4b`, `crow-9b` |
| 16 GB RAM | `nemotron-4b` |
| Battery life mode / quick smoke test | `tiny` |
| Vision (images) on a heavy model | `qwen36-35b` or `gemma4-26b` |
| Vision on a small model | `qwen35-9b` (best quality) or `gemma4-e4b` |

`make models` shows what's installed.

---

## Per-model recipes

Each recipe shows: how to start, the right `KV`/`CTX`, the model's strengths, a sample prompt, and the actual reply you should see.

### `qwen36-35b` — default flagship (Qwen 3.6 35B-A3B MoE)

**Start:**
```bash
make start                              # uses turbo3, 128K ctx
# equivalent: MODEL=qwen36-35b CTX=131072 KV=turbo3 ./scripts/start-turboquant.sh
```

**Strengths:** Highest quality on this hardware, **128K context** with TurboQuant, MoE architecture means only ~3 B params are active per token (fast generation despite 35 B total). Vision-capable via `mmproj`.

**Sample prompt — reasoning (with chain-of-thought):**
```bash
curl -s http://127.0.0.1:10501/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model":"local",
    "messages":[{"role":"user","content":"Three boxes labeled wrongly: Apples, Oranges, Mixed. Each label is wrong. You can pick one fruit from one box. How do you label all three correctly?"}],
    "max_tokens":2000,
    "chat_template_kwargs":{"enable_thinking":true}
  }' | jq -r '.choices[0].message.content' | tail -20
```

> **Important:** with `enable_thinking:true`, Qwen consumes a *lot* of tokens reasoning inside `<think>...</think>` before producing visible content. Budget **at least 1500–2000 max_tokens** or the visible reply will be empty. If you only want the answer (and don't care to read the thinking), pass `enable_thinking:false` — the model still arrives at the right answer for puzzles like this.

The model's correct answer: pick from the box labeled "Mixed". Whatever fruit you draw must be the contents of that box (label is wrong → it's not Mixed → it's pure). The other two boxes get labeled by elimination, since each was also mislabeled.

**Sample prompt — long-context code review:**
```bash
# Stuff a real codebase: concatenate up to 100K tokens of source
PROMPT=$(jq -nc \
  --arg p "$(cat $(find ~/myproject -name '*.py' | head -50))"$'\n\nReview this codebase. List the 3 worst smells and how to fix.' \
  '{model:"local", messages:[{role:"user", content:$p}], max_tokens:800, chat_template_kwargs:{enable_thinking:false}}')
curl -s http://127.0.0.1:10501/v1/chat/completions -H "Content-Type: application/json" -d "$PROMPT"
```
At ~50K tokens, prompt processing runs ~560 tok/s → ~90 s prefill before the reply. Worth it for whole-repo review.

**When NOT to use:** if you need <2 s response time on short prompts (use a small model).

---

### `gemma4-26b` — Gemma 4 26B-A4B (MoE)

**Start:**
```bash
make start-gemma4-26b                   # 32K ctx, turbo3 KV
```

**Strengths:** Different family than Qwen — useful when you want a second opinion or your prompt triggers a Qwen quirk. ~17 GB on disk, MoE so generation is brisk (≈80 tok/s on M3 Max).

**Sample prompt — code generation:**
```bash
curl -s http://127.0.0.1:10501/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model":"local",
    "messages":[
      {"role":"system","content":"You are a precise code generator. Output only code, no commentary."},
      {"role":"user","content":"Write a Python function that returns the n-th Fibonacci number using matrix exponentiation."}
    ],
    "max_tokens":400,
    "temperature":0.2
  }' | jq -r '.choices[0].message.content'
```

**Note:** Gemma's chat template does **not** support Qwen's `enable_thinking` flag. Drop the `chat_template_kwargs` for Gemma — it'll error or ignore it.

---

### `gemma4-e4b` — Gemma 4 E4B (small dense)

**Start:**
```bash
make start-gemma4-e4b                   # 16K ctx, turbo3 KV
```

**Strengths:** Compact (~8 GB), runs on machines with 16 GB free RAM. Same Gemma 4 family quality character as the 26B but smaller. ~50 tok/s.

**Sample prompt — quick summary:**
```bash
curl -s http://127.0.0.1:10501/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"Summarize the plot of Hamlet in 3 sentences."}],"max_tokens":200,"temperature":0.6}' \
  | jq -r '.choices[0].message.content'
```

---

### `gpt-oss-20b` — OpenAI 20B open-weights (MXFP4)

**Start:**
```bash
make start-gpt-oss                      # 32K ctx, q8_0 KV (turbo3 unsupported on MXFP4)
```

**Strengths:** Behaviorally close to OpenAI's hosted instruct models. Useful if your prompts are tuned for ChatGPT-style replies. MXFP4 weights are ~12 GB on disk.

**Why `q8_0` instead of turbo3:** the TurboQuant turbo3 kernel doesn't currently handle MXFP4 weight + KV combinations on Metal — you'll get `Abort trap: 6` during model load. q8_0 KV-cache works fine and still halves memory vs f16.

**Sample prompt — instruction following:**
```bash
curl -s http://127.0.0.1:10501/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model":"local",
    "messages":[{"role":"user","content":"In exactly 5 bullets, list the most important Git commands for a beginner."}],
    "max_tokens":300,
    "temperature":0.5
  }' | jq -r '.choices[0].message.content'
```

**Note:** No `enable_thinking` flag — different chat template than Qwen.

---

### `qwen35-9b` — Qwen 3.5 9B (dense)

**Start:**
```bash
make start-qwen35-9b                    # 32K ctx, turbo3 KV
```

**Strengths:** Older Qwen generation but still excellent. Dense 9 B → predictable performance, no MoE routing surprises. Vision-capable. ~50 tok/s with thinking off.

**Sample prompt — translation:**
```bash
curl -s http://127.0.0.1:10501/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model":"local",
    "messages":[{"role":"user","content":"Translate to Japanese: \"The local model preserves my privacy and works offline.\""}],
    "max_tokens":120,
    "chat_template_kwargs":{"enable_thinking":false}
  }' | jq -r '.choices[0].message.content'
```

---

### `crow-9b` — Crow-9B (Qwen3.5 distill from Opus 4.6)

**Start:**
```bash
make start-crow                         # 16K ctx, turbo3 KV
```

**What's a "distill"?** Crow-9B is a Qwen3.5 9B base fine-tuned on outputs from Anthropic Claude Opus 4.6. The intent is to capture some of Opus's response style/quality in a 9B model. Useful for users who like Opus's long-form, careful answers.

**Sample prompt — careful reasoning:**
```bash
curl -s http://127.0.0.1:10501/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model":"local",
    "messages":[{"role":"user","content":"Should I use a singleton or a factory for managing a database connection pool? Walk me through the trade-offs."}],
    "max_tokens":600,
    "temperature":0.5
  }' | jq -r '.choices[0].message.content'
```

---

### `nemotron-4b` — NVIDIA Nemotron-3 Nano 4B

**Start:**
```bash
make start-nemotron                     # 8K ctx, turbo3 KV
```

**Strengths:** Tiny footprint (~2.6 GB), solid for a 4B model, runs at ~100 tok/s on M3 Max. NVIDIA's instruct-tuned quality. Good when you need speed > absolute capability.

**Sample prompt — quick summary:**
```bash
curl -s http://127.0.0.1:10501/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"What is the difference between TCP and UDP? One paragraph."}],"max_tokens":200}' \
  | jq -r '.choices[0].message.content'
```

---

### `qwen36-27b` — Qwen 3.6 27B IQ2_XXS (dense)

**Start:**
```bash
make start-qwen36-27b                   # 32K ctx, turbo3 KV
```

**When to use:** If `qwen36-35b` won't fit in your free RAM (e.g. another big app is open, or you have a 32 GB Mac). Vision-capable. IQ2_XXS is an aggressive quant — quality drops noticeably below the 35B-Q6_K but it's still usable. ~9 GB.

---

### `tiny` — TinyLlama 1.1B

**Start:**
```bash
make start-tiny                         # 2K ctx, q8_0 KV (turbo3 unsupported, head dim too small)
```

**When to use:**
- Smoke-testing the stack without waiting 30 s for a big model to load.
- "Is the server even alive?" — TinyLlama loads in ~3 s, replies at ~270 tok/s.
- Low-power demos.

**Sample:**
```bash
curl -s http://127.0.0.1:10501/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"Say hi."}],"max_tokens":40}' \
  | jq -r '.choices[0].message.content'
```

**Don't expect quality** — this is a 1.1 B model. It will hallucinate, miss instructions, and write awkwardly.

---

## Workflows

### Streaming chat — three languages

#### curl (raw SSE)
```bash
curl -sN http://127.0.0.1:10501/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"Tell me a haiku about offline AI."}],"max_tokens":120,"stream":true,"chat_template_kwargs":{"enable_thinking":false}}' \
  | grep --line-buffered "^data: " \
  | sed -u 's/^data: //' \
  | grep -v '^\[DONE\]$' \
  | jq -r --unbuffered '.choices[0].delta.content // empty'
```

**Heads-up:** the first chunk usually has `content: null` (the model is just declaring `role: assistant`). The `// empty` filter drops nulls. If you write your own parser, also handle the case where `content` is missing or `null`, not just empty-string.

#### Python (stdlib only)
```python
import json, urllib.request

body = json.dumps({
    "model": "local",
    "messages": [{"role": "user", "content": "Tell me a haiku about offline AI."}],
    "max_tokens": 120,
    "stream": True,
    "chat_template_kwargs": {"enable_thinking": False},
}).encode()

req = urllib.request.Request("http://127.0.0.1:10501/v1/chat/completions",
                             data=body, headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req) as r:
    for raw in r:
        line = raw.decode().rstrip()
        if not line.startswith("data: "): continue
        if line == "data: [DONE]": break
        chunk = json.loads(line[6:], strict=False)
        delta = chunk["choices"][0].get("delta", {}).get("content")
        # delta is `None` on the first chunk (role-only); skip those.
        if delta:
            print(delta, end="", flush=True)
print()
```

(See `clients/python-demo.py` and `scripts/bench.py` for the polished versions.)

#### Node / browser fetch
```js
const r = await fetch('http://127.0.0.1:10501/v1/chat/completions', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    model: 'local',
    messages: [{ role: 'user', content: 'Tell me a haiku about offline AI.' }],
    max_tokens: 120,
    stream: true,
    chat_template_kwargs: { enable_thinking: false },
  }),
});
const reader = r.body.getReader();
const dec = new TextDecoder();
let buf = '';
for (;;) {
  const { value, done } = await reader.read();
  if (done) break;
  buf += dec.decode(value, { stream: true });
  const lines = buf.split('\n'); buf = lines.pop();
  for (const ln of lines) {
    if (!ln.startsWith('data: ')) continue;
    if (ln === 'data: [DONE]') return;
    const j = JSON.parse(ln.slice(6));
    process.stdout.write(j.choices?.[0]?.delta?.content || '');
  }
}
```

`clients/web-demo.html` is a complete single-file streaming UI built on this.

---

### Long-context document QA / RAG

```bash
# Stuff a doc into the context and ask a question
DOC=$(cat docs/architecture.md docs/models.md docs/api.md docs/usage.md)
curl -s http://127.0.0.1:10501/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "$(jq -nc --arg d "$DOC" \
    '{model:"local",
      messages:[
        {role:"system", content:"You are answering questions about the local Qwen stack documentation."},
        {role:"user",   content:"DOCS:\n\($d)\n\nQuestion: which models do not support TurboQuant turbo3 and why?"}
      ],
      max_tokens:300,
      chat_template_kwargs:{enable_thinking:false}}')" \
  | jq -r '.choices[0].message.content'
```

For prompts above ~50 K tokens, `qwen36-35b` is the only model with the trained context. For 8K–32K, any model works.

**Verify it actually used the long context:**
```bash
curl -s http://127.0.0.1:10501/slots | jq '.[0] | {n_prompt_tokens_processed, n_decoded}'
```

---

### Vision (image input)

Vision-capable models load `--mmproj` automatically when started via `start-vision.sh`:

```bash
# Stop default server, start with vision
./scripts/stop-all.sh
MODEL=qwen35-9b PORT=10503 ./scripts/start-vision.sh > logs/vision.log 2>&1 &
sleep 30
./scripts/test-vision.sh                # generates a test PNG and queries it
```

Real image:
```bash
B64=$(base64 -i ~/Desktop/photo.jpg | tr -d '\n')
curl -s http://127.0.0.1:10503/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "$(jq -nc --arg img "data:image/jpeg;base64,$B64" \
    '{model:"local",
      messages:[{role:"user", content:[
        {type:"text", text:"Describe what is in this image. Be specific."},
        {type:"image_url", image_url:{url:$img}}
      ]}],
      max_tokens:400}')" \
  | jq -r '.choices[0].message.content'
```

Vision models on this stack: `qwen36-35b`, `qwen36-27b`, `gemma4-26b`, `gemma4-e4b`, `qwen35-9b`, `crow-9b`. Confirm via `make models` (look for the 🖼 marker in `make info`).

---

### JSON / structured output

The naive approach:
```bash
curl -s http://127.0.0.1:10501/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model":"local",
    "messages":[
      {"role":"system","content":"Reply with valid JSON only. No prose."},
      {"role":"user","content":"Extract: name, age, city, occupation. Source: \"Marcus, 41, works as a marine biologist in Lisbon.\""}
    ],
    "max_tokens":150,
    "temperature":0.0,
    "chat_template_kwargs":{"enable_thinking":false}
  }' | jq -r '.choices[0].message.content'
```

Real output from `qwen36-35b` (verified):
````
```json
{
  "name": "Marcus",
  "age": 41,
  "city": "Lisbon",
  "occupation": "marine biologist"
}
```
````

The model wraps the JSON in markdown code fences even when told not to — that's a robust default for chat formatting. Strip the fences:
```bash
... | sed -E 's/^```(json)?//; s/```$//' | jq .
```

**Cleaner: use `response_format`** to constrain via the server's grammar sampler.

`json_object` produces a JSON object but **still needs a system prompt** telling the model to output JSON — otherwise the model generates prose-shaped JSON like `"Here is the data: {...}"` and the wrapper text often gets mangled.

```bash
curl -s http://127.0.0.1:10501/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model":"local",
    "messages":[
      {"role":"system","content":"Output JSON only."},
      {"role":"user","content":"Extract name, age, city, occupation from: Marcus, 41, marine biologist, Lisbon."}
    ],
    "max_tokens":150,
    "temperature":0.0,
    "response_format":{"type":"json_object"},
    "chat_template_kwargs":{"enable_thinking":false}
  }' | jq -r '.choices[0].message.content' | jq .
```

**Strictest: `json_schema`** — locks the keys, types, and required fields. Works without a system prompt because the grammar leaves the model no other choice.

```bash
curl -s http://127.0.0.1:10501/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model":"local",
    "messages":[{"role":"user","content":"Extract name, age, city, occupation from: Marcus, 41, marine biologist, Lisbon."}],
    "max_tokens":150,
    "temperature":0.0,
    "response_format":{
      "type":"json_schema",
      "json_schema":{
        "name":"person",
        "schema":{
          "type":"object",
          "properties":{
            "name":{"type":"string"},
            "age":{"type":"integer"},
            "city":{"type":"string"},
            "occupation":{"type":"string"}
          },
          "required":["name","age","city","occupation"]
        }
      }
    },
    "chat_template_kwargs":{"enable_thinking":false}
  }' | jq -r '.choices[0].message.content' | jq .
```

Both verified on `qwen36-35b`; same behavior on `gemma4-26b`, `qwen35-9b`, `gpt-oss-20b`. It's a sampler-side trick, not a model-side one — works on every loaded model.

---

### Multi-turn conversation

```bash
HIST=$(mktemp)
echo '[]' > "$HIST"
say() {
  local msg="$1"
  jq --arg m "$msg" '. += [{"role":"user","content":$m}]' "$HIST" > "$HIST.new" && mv "$HIST.new" "$HIST"
  resp=$(curl -s http://127.0.0.1:10501/v1/chat/completions -H "Content-Type: application/json" \
    -d "$(jq -nc --slurpfile h "$HIST" '{model:"local", messages:$h[0], max_tokens:300, chat_template_kwargs:{enable_thinking:false}}')")
  reply=$(echo "$resp" | python3 -c "import json,sys; print(json.loads(sys.stdin.read(),strict=False)['choices'][0]['message']['content'])")
  echo "─── assistant ───"
  echo "$reply"
  jq --arg m "$reply" '. += [{"role":"assistant","content":$m}]' "$HIST" > "$HIST.new" && mv "$HIST.new" "$HIST"
}

say "I'm planning a 2-week trip to Japan in spring."
say "Suggest a 3-city route."
say "How would I get between them?"
```

`scripts/demo-chat.sh` is the polished version of this loop. Use `THINK=1 ./scripts/demo-chat.sh` to keep thinking on.

---

### Switching models live (stop and swap)

```bash
make stop                                  # kill whatever's running
make start-gemma4-26b                      # start Gemma instead
sleep 30                                   # wait for load
./scripts/healthcheck.sh                   # confirm
```

Or one-liner with a custom model:
```bash
MODEL=crow-9b CTX=16384 KV=turbo3 ./scripts/start-turboquant.sh > logs/turboquant.log 2>&1 &
```

To switch the **always-on** default (what launchd starts at login), edit `configs/launchd-plist.template` and change `start-turboquant.sh` to e.g. `start-gemma4-26b`, then `make uninstall-launchd && make install-launchd`.

Two servers at once usually OOMs the GPU with big models. The exception is when both are small (e.g. `tiny` + `nemotron-4b`, both <3 GB).

---

## Performance tips

### Prompt processing scales with batch size for long inputs
For 50K+ token prompts, prompt processing dominates. Defaults (`--batch-size 2048 --ubatch-size 512`) are good — don't lower them unless you're memory-constrained.

### Disable thinking for benchmarks and short queries
Qwen 3.6's chat template defaults to `enable_thinking:true`. Every request budgets some tokens to internal `<think>...</think>`. For short replies, those tokens get *all* of `max_tokens` and you see an empty `content`. Always pass:
```json
"chat_template_kwargs": {"enable_thinking": false}
```
unless you actually want chain-of-thought.

### Plug in for sustained jobs
M3 Max throttles ~30 % on battery for sustained GPU loads. For long benchmarks or document QA, plug in.

### Mixing K and V cache types is a trap
We benched it: `f16/turbo3` and `turbo3/f16` ran 50 % slower than either pure config. Always set `-ctk` and `-ctv` to the same value (which all our scripts do).

### Cold start is dominated by mmap warmup
First load after reboot reads the GGUF off SSD (fastest path is ~3 GB/s on M3 Max). For a 28 GB model that's ~10 s of paging. Subsequent restarts reuse the OS file cache — `make stop && make start` is then ~3 s.

---

## Editor integration

### Continue (VS Code)
Drop `configs/continue.json` into `~/.continue/config.json` (merge if you have one). It points at `:10501` (turboquant) and `:10500` (baseline). To use a different model, just `make start-<alias>` — Continue talks to whatever's on the port.

### OpenCode
Drop `configs/opencode.json` into `~/.config/opencode/config.json`. Same idea — port-based, not model-name-based.

### Zed
Add to `~/.config/zed/settings.json`:
```json
{
  "language_models": {
    "openai_compatible": [
      {
        "name": "qwen-local",
        "api_url": "http://127.0.0.1:10501/v1",
        "api_key": "no-key",
        "available_models": [{ "name": "local", "max_tokens": 131072 }]
      }
    ]
  }
}
```

### Aider
```bash
export OPENAI_API_BASE=http://127.0.0.1:10501/v1
export OPENAI_API_KEY=no-key
aider --model openai/local
```

---

## Troubleshooting recipes

### "It won't load — `Abort trap: 6`"
The model isn't compatible with the `KV=turbo3` kernel. Retry with `q8_0`:
```bash
make stop
MODEL=<alias> KV=q8_0 ./scripts/start-turboquant.sh > logs/turboquant.log 2>&1 &
```
Known incompatible: `tiny` (head dim too small), `gpt-oss-20b` (MXFP4 weights). Their Make targets pre-set q8_0 already.

### "Empty replies"
Your prompt's `max_tokens` is being eaten by Qwen's thinking mode. Add `"chat_template_kwargs": {"enable_thinking": false}` or bump `max_tokens` to 1024+.

### "HTTP 400"
Usually `prompt_n + max_tokens > n_ctx`. Check the loaded context with `make info` (look for "context loaded"). Either restart with bigger `CTX=` or shorten the prompt.

### "Two models at once OOMs"
Each big model claims its full weight footprint on GPU (≈26 GB for `qwen36-35b`). Two on a 64 GB Mac → over the recommendedMaxWorkingSetSize. Run them sequentially. Or use one big + one tiny.

### "Server starts but `/health` never returns 200"
Watch the log:
```bash
tail -f logs/turboquant.log
```
Common causes: `model file not found` (run `make models` and re-symlink), Metal shader compile error (Xcode CLT vs full Xcode mismatch), out of disk for shader cache.

### "Slow first request only"
First request is cold. Always warm up before measuring:
```bash
curl -s http://127.0.0.1:10501/v1/chat/completions -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' >/dev/null
# now measure
```

### "I changed the launchd plist and nothing happened"
launchd caches by label. Force reload:
```bash
make uninstall-launchd
make install-launchd
```

---

## See also

- [`docs/api.md`](api.md) — every server endpoint
- [`docs/models.md`](models.md) — model matrix + smoke-test results
- [`docs/multimodal.md`](multimodal.md) — vision pipeline detail
- [`docs/offline-mode.md`](offline-mode.md) — provably-offline operation
- [`docs/troubleshooting.md`](troubleshooting.md) — broader gotchas
- [`benchmarks/RESULTS.md`](../benchmarks/RESULTS.md) and [`benchmarks/SWEEP.md`](../benchmarks/SWEEP.md) — perf data
