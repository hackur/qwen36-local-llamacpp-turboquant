# Install the Qwen3.8 artifacts

The only supported pair is the LM Studio community mirror of Qwen3.8-27B:

```text
Qwen3.8-27B-Q8_0.gguf
mmproj-Qwen3.8-27B-BF16.gguf
```

LM Studio users can download that model normally, then run:

```bash
make model-link
```

For a custom model root:

```bash
MODELS_ROOT=/Volumes/models make model-link
```

The root must preserve this relative layout:

```text
lmstudio-community/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q8_0.gguf
lmstudio-community/Qwen3.8-27B-GGUF/mmproj-Qwen3.8-27B-BF16.gguf
```

Direct Hugging Face download:

```bash
huggingface-cli download lmstudio-community/Qwen3.8-27B-GGUF \
  Qwen3.8-27B-Q8_0.gguf mmproj-Qwen3.8-27B-BF16.gguf \
  --local-dir /path/to/ggufs/lmstudio-community/Qwen3.8-27B-GGUF
MODELS_ROOT=/path/to/ggufs make model-link
```

`make model-link` removes non-Qwen3.8 symlinks from this repository only. It
never deletes the source GGUFs from LM Studio or a custom model store.
