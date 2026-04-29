# Multimodal (vision) — per-model recipes

Six models in this stack are vision-capable. Each ships with a matching `mmproj` file (vision projector) that gets symlinked alongside the weights:

| Alias | mmproj quant | Size of mmproj | Notes |
|---|---|---|---|
| `qwen36-35b` | BF16 | 0.9 GB | best quality |
| `qwen36-27b` | F32 | 1.8 GB | dense 27B fallback |
| `gemma4-26b` | BF16 | 1.2 GB | Gemma 4 vision |
| `gemma4-e4b` | BF16 | 1.0 GB | small Gemma 4 vision |
| `qwen35-9b` | BF16 | 0.9 GB | Qwen 3.5 vision (older) |
| `crow-9b` | F16 | 0.9 GB | distill (vision via the underlying Qwen3.5) |

`make models` shows which are vision-capable (🖼 in the VISION column).

## Quickstart

```bash
make stop                                     # vision needs its own server
MODEL=qwen36-35b PORT=10503 ./scripts/start-vision.sh > logs/vision.log 2>&1 &
sleep 30                                      # ~30 s to load weights + mmproj on M3 Max
./scripts/test-vision.sh                      # generates a 32×32 PNG and asks for color
```

Expected reply: a description like "The image is solid red."

## Custom image

Send any local file as base64. The server expects the OpenAI `image_url` content shape:

```bash
B64=$(base64 -i ~/Desktop/photo.jpg | tr -d '\n')
curl -s http://127.0.0.1:10503/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "$(jq -nc --arg img "data:image/jpeg;base64,$B64" \
    '{model:"local",
      messages:[{role:"user", content:[
        {type:"text", text:"Describe this image. Mention objects, setting, mood, and any text you can read."},
        {type:"image_url", image_url:{url:$img}}
      ]}],
      max_tokens:500,
      chat_template_kwargs:{enable_thinking:false}}')" \
  | jq -r '.choices[0].message.content'
```

Both `image/jpeg` and `image/png` MIME types work. PDFs and videos are not supported.

## Switching the vision model

```bash
make stop
MODEL=qwen35-9b PORT=10503 ./scripts/start-vision.sh > logs/vision.log 2>&1 &
```

`MODEL=` accepts any of the six vision aliases listed above. The script auto-finds the matching `<alias>.mmproj.gguf` next to the weights symlink.

## Two servers at once: text + vision

The 64 GB on this M3 Max isn't enough for `qwen36-35b` text + `qwen36-35b` vision simultaneously (each takes ~28 GB on GPU). Workable combinations:

- **`qwen36-35b` text on :10501 + `gemma4-e4b` vision on :10503** — ~28 + 8 GB, fits
- **`qwen35-9b` text on :10501 + `qwen35-9b` vision on :10503** — ~9 + 9 GB easily fits, lets you ask vision-and-text in parallel

Don't try `qwen36-35b` text + `gemma4-26b` vision — combined 28 + 16 = 44 GB on top of compute scratch will OOM.

## VRAM cost of vision

The `mmproj` runs *in addition* to the LLM weights. Approximate at runtime:
- Qwen 3.6 35B-A3B: weights 26.8 GB + mmproj ~2 GB = **~29 GB**
- Gemma 4 26B-A4B: weights ~16 GB + mmproj ~1.5 GB = **~18 GB**
- Qwen 3.5 9B: weights ~9 GB + mmproj ~1 GB = **~10 GB**

## Notes

- mmproj **must match** the base model. Mixing (e.g. Qwen mmproj + Gemma weights) produces gibberish or aborts.
- `start-vision.sh` validates this for you — it grabs `<alias>.mmproj.gguf` next to `<alias>.gguf` and errors out if missing.
- TurboQuant's `-ctk turbo3` works fine alongside `--mmproj`. The KV-cache compression is on the LLM side; the projector is independent.
- Vision generation is generally slower than text-only — first-token latency is dominated by the image encoding step (~1–3 s for a 1080p image).
