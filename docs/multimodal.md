# Multimodal (vision) with mmproj

Both Qwen3.6 GGUFs ship with an `mmproj` (multimodal projector) file. Pass it via `--mmproj` and the OpenAI `image_url` content type starts working.

## Start a vision-capable server

Edit `scripts/start-baseline.sh` (or your own copy) and add:

```bash
--mmproj "$MMPROJ_PRIMARY"
```

…right after `-m "$MODEL"`. Or one-liner from the repo root:

```bash
vendor/llama.cpp-mainline/build/bin/llama-server \
  -m   ~/.lmstudio/models/lmstudio-community/Qwen3.6-35B-A3B-GGUF/Qwen3.6-35B-A3B-Q6_K.gguf \
  --mmproj ~/.lmstudio/models/lmstudio-community/Qwen3.6-35B-A3B-GGUF/mmproj-Qwen3.6-35B-A3B-BF16.gguf \
  -ngl 99 -fa on -c 32768 --host 127.0.0.1 --port 10500
```

## Send an image

```bash
img=$(base64 -i path/to/photo.jpg | tr -d '\n')
curl -s http://127.0.0.1:10500/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "$(jq -nc --arg img "data:image/jpeg;base64,$img" '
    {model:"local",
     messages:[{role:"user", content:[
       {type:"text", text:"Describe this image."},
       {type:"image_url", image_url:{url:$img}}
     ]}]}')" \
  | jq -r '.choices[0].message.content'
```

## Notes

- mmproj **must match** the base model — Qwen3.6-35B-A3B's mmproj does not work with the 27B.
- VRAM cost: ~1.5–2 GB extra for the vision tower at runtime.
- TurboQuant's `-ctk turbo3` is a KV-cache-side quantization; it doesn't touch the vision projector, so it should compose with `--mmproj` cleanly. Verify in practice.
