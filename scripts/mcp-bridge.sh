#!/usr/bin/env bash
# Wrap a stdio MCP server with supergateway so the llama.cpp WebUI can
# reach it over SSE (browsers can't talk stdio). One bridge per server.
#
# Usage:
#   scripts/mcp-bridge.sh fs            # filesystem, sandboxed to $REPO, port 4001
#   scripts/mcp-bridge.sh fs /some/dir  # filesystem, sandboxed to /some/dir
#   scripts/mcp-bridge.sh time          # time server, port 4002
#   scripts/mcp-bridge.sh git           # git server (sandboxed to $REPO), port 4003
#   MCP_PORT=4099 scripts/mcp-bridge.sh fs   # custom port
#
# Then in the WebUI: Settings → MCP → Add New Server → http://127.0.0.1:<port>/mcp
# (Streamable HTTP transport — the WebUI's only supported MCP transport.)
#
# Requirements: npx (Node 20+).  We never auto-install supergateway —
# the first run will pull it; subsequent runs reuse the npx cache.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"

command -v npx >/dev/null || {
  echo "❌ npx not on PATH. Install Node 20+ (e.g. brew install node)." >&2
  exit 1
}

NAME="${1:-}"
case "$NAME" in
  fs|filesystem)
    ROOT="${2:-$REPO}"
    [[ -d "$ROOT" ]] || { echo "❌ filesystem root not a dir: $ROOT" >&2; exit 1; }
    PORT="${MCP_PORT:-4001}"
    STDIO="npx -y @modelcontextprotocol/server-filesystem $ROOT"
    LABEL="filesystem ($ROOT)"
    ;;
  time)
    PORT="${MCP_PORT:-4002}"
    STDIO="npx -y @modelcontextprotocol/server-time"
    LABEL="time"
    ;;
  git)
    PORT="${MCP_PORT:-4003}"
    STDIO="npx -y @modelcontextprotocol/server-git --repository $REPO"
    LABEL="git ($REPO)"
    ;;
  ""|-h|--help)
    sed -n '2,15p' "$0"; exit 0
    ;;
  *)
    echo "❌ unknown server '$NAME'. Try: fs | time | git" >&2; exit 1
    ;;
esac

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then
  echo "❌ port $PORT already listening — pick another with MCP_PORT=…" >&2
  exit 1
fi

echo "▶ MCP bridge: $LABEL  →  http://127.0.0.1:$PORT/mcp  (Streamable HTTP)"
echo "  add this URL in WebUI: Settings → MCP → Add New Server"
echo "  Ctrl-C to stop."
# --cors so the llama.cpp WebUI (different origin) can connect directly.
# Locked to the llama-server origin; override with MCP_CORS=* for broader access.
# Streamable HTTP is the only MCP transport the WebUI accepts.
CORS_ORIGIN="${MCP_CORS:-http://127.0.0.1:10501}"
exec npx -y supergateway \
  --stdio "$STDIO" \
  --outputTransport streamableHttp \
  --port "$PORT" \
  --cors "$CORS_ORIGIN"
