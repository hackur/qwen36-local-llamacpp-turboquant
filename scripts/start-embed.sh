#!/usr/bin/env bash
# embed-server:v1 — companion embeddings server on :10510.
# llama-server can only host one model at a time and the chat models in this
# repo aren't embedding models, so /v1/embeddings on :10501 returns 501. This
# script starts a second llama-server (mainline build) with --embedding so
# /v1/embeddings works.
#
# No embedding GGUF is bundled. Drop one in (e.g. nomic-embed-text-v1.5.Q8_0.gguf
# from https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF, or
# mxbai-embed-large-v1 / bge-small-en-v1.5 GGUFs) and pass its path:
#   MODEL=/path/to/nomic-embed-text-v1.5.Q8_0.gguf ./scripts/start-embed.sh
# Or, if you've added an `embed` alias via scripts/symlink-models.sh:
#   ./scripts/start-embed.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_common.sh"

PORT="${PORT:-10510}"
CTX="${CTX:-8192}"           # embedders are short-context by design
KV="${KV:-f16}"              # tiny KV — no point quantizing
MODEL_INPUT="${MODEL:-$REPO/models/embed.gguf}"
BIN="$REPO/vendor/llama.cpp-mainline/build/bin/llama-server"
LOG="$REPO/logs/embed.log"

[[ -x "$BIN" ]] || { echo "❌ Mainline not built. Run scripts/build-llama.sh"; exit 1; }

if [[ "$MODEL_INPUT" == "$REPO/models/embed.gguf" && ! -f "$MODEL_INPUT" ]]; then
  cat >&2 <<EOF
❌ No embedding model found at ./models/embed.gguf
   This repo does not bundle one. Options:
     1. Download an embedding GGUF, e.g.
        https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF
        and either symlink it as ./models/embed.gguf or pass its path:
          MODEL=/abs/path/to/nomic-embed-text-v1.5.Q8_0.gguf $0
     2. Other lightweight options: mxbai-embed-large-v1, bge-small-en-v1.5,
        gte-small — any GGUF tagged as an embedding model will work.
EOF
  exit 1
fi

resolve_model "$MODEL_INPUT"
MODEL="$RESOLVED_MODEL"
ensure_model "$MODEL"
load_model_defaults "$MODEL_INPUT"
ensure_no_other_llama_server
ensure_port_free "$PORT"
mkdir -p "$REPO/logs"

# mixed-kv-guard:v1 — derive KV_K / KV_V from KV (unless overridden) and warn on mismatch.
apply_kv_split

KV_DESC="$KV_K"; [[ "$KV_K" != "$KV_V" ]] && KV_DESC="${KV_K}/${KV_V}"
echo "▶ embed @ http://127.0.0.1:$PORT  (--embedding, ${KV_DESC} KV, ${CTX} ctx)"
echo "  model → $MODEL"
echo "  log   → $LOG"

# Note: we do NOT pass ${SAMPLING[@]} — sampling is irrelevant for embeddings.
# We also drop --jinja since embedders don't use chat templates.
exec "$BIN" \
  -m "$MODEL" \
  --port "$PORT" \
  --host 127.0.0.1 \
  -c "$CTX" \
  -ctk "$KV_K" -ctv "$KV_V" \
  -ngl 99 -fa on -np 1 \
  --embedding \
  --alias embed \
  2>&1 | tee "$LOG"
