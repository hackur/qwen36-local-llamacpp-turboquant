#!/usr/bin/env bash
# Send a test image to the vision server (defaults to a tiny PNG we generate).
set -euo pipefail
PORT="${PORT:-10503}"
IMG="${1:-}"

if [[ -z "$IMG" ]]; then
  # Make a 32×32 red PNG via Python so we don't need an image on disk.
  IMG="$(mktemp -t vision-test.XXXXXX.png)"
  trap 'rm -f "$IMG"' EXIT
  python3 - "$IMG" <<'PY'
import sys, struct, zlib
path = sys.argv[1]
def chunk(t, d):
    return struct.pack(">I",len(d))+t+d+struct.pack(">I", zlib.crc32(t+d)&0xffffffff)
W=H=32
ihdr = struct.pack(">IIBBBBB", W,H,8,2,0,0,0)
raw = b""
for y in range(H):
    raw += b"\x00" + b"\xFF\x00\x00"*W
idat = zlib.compress(raw)
png = b"\x89PNG\r\n\x1a\n"+chunk(b"IHDR",ihdr)+chunk(b"IDAT",idat)+chunk(b"IEND",b"")
open(path,"wb").write(png)
print(f"  wrote 32x32 red PNG → {path}", file=sys.stderr)
PY
fi

if ! curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  echo "no vision server on :$PORT — start with scripts/start-vision.sh"; exit 1
fi

B64=$(base64 -i "$IMG" | tr -d '\n')
echo "▶ sending image to :$PORT (base64 length: ${#B64})"

curl -s "http://127.0.0.1:$PORT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc --arg img "data:image/png;base64,$B64" '
    {model:"local",
     messages:[{role:"user", content:[
       {type:"text", text:"What dominant color is this image?"},
       {type:"image_url", image_url:{url:$img}}
     ]}],
     max_tokens:80,
     chat_template_kwargs:{enable_thinking:false}}')" \
  | python3 -c "import sys,json; r=json.load(sys.stdin,strict=False); print('  reply:', r['choices'][0]['message']['content'])"
