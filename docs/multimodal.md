# Vision

Vision is part of the default server, not a second launcher. The matching BF16
projector is always loaded with the Qwen3.8 Q8_0 weights on `:10501`.

The runtime passes `--image-min-tokens 1024`, matching the llama.cpp warning
for Qwen dynamic-resolution grounding tasks. Use the native WebUI attachment
button or an OpenAI-compatible content array.

```json
{
  "model": "qwen3.8-local",
  "messages": [{
    "role": "user",
    "content": [
      {"type": "text", "text": "Describe this image precisely."},
      {"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}}
    ]
  }]
}
```

Run `make vision` for the generated local fixture. MTP and the projector are
loaded together; the engine skips image-embedding rows during draft prefill and
uses MTP for eligible generated text. Treat a live vision smoke as mandatory
after any engine update.
