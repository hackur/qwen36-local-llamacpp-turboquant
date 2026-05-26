# MCP integration in the llama.cpp WebUI

Investigation 2026-05-25. Live inspection of the running turboquant
server at `http://127.0.0.1:10501/` + verification against the
mainline llama-server `--help` output and upstream PR #18655.

## TL;DR

**MCP support is already shipping in our binaries.** Both
`vendor/llama.cpp-mainline` (HEAD `35c9b1f3`, 2026-05-25) and
`vendor/llama-cpp-turboquant` (HEAD `11a241d`, 2026-04-24) compile the
new WebUI with the MCP client built in. The chat at
`http://127.0.0.1:10501/` already exposes:

- **Sidebar**: "MCP Servers" button.
- **Settings → MCP tab**: agentic loop max turns (default 10), max
  tool-preview lines (default 25), "show tool call in progress" toggle,
  and a server manager.
- **Add New Server form**: `Server URL *` (placeholder
  `https://mcp.example.com/sse`) + optional custom headers.

What's missing in *our* setup is just the **server-side CORS proxy
flag**. The WebUI button is there; tool calls fail without the proxy
because browsers refuse cross-origin requests to user-configured MCP
endpoints.

## Architecture (as built)

```
            Browser (localStorage)
            ├── chat UI  ──────► POST /v1/chat/completions ─► llama-server
            └── MCP client
                  └── HTTP/SSE ─► (CORS proxy on llama-server) ─► user-MCP servers
                                  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                                  enabled by --ui-mcp-proxy
```

- **Transport**: HTTP/SSE only. The form's URL placeholder
  (`/sse`) and the absence of a transport selector confirm
  streamable-HTTP MCP servers only.
- **Storage**: per-browser localStorage. Server list is not shared
  across users / browsers.
- **Agentic loop**: browser-side. The UI runs N turns of
  `chat-completion → parse tool calls → call MCP → feed back`, capped
  by "max turns".
- **Chat template**: must be tool-capable. Our `--jinja` + Froggeric
  template (`configs/chat-templates/chat_template.jinja`) already
  parses Qwen tool-call XML correctly — that's the same template fix
  we applied for `chat_template_flags` in `_common.sh`.

## Flag history

| Flag                 | Status     | Where                |
|----------------------|------------|----------------------|
| `--webui-mcp-proxy`  | deprecated | turboquant fork (only one available there) |
| `--ui-mcp-proxy`     | current    | mainline (also accepts the deprecated form) |

Help text warns: *"experimental: whether to enable MCP CORS proxy — do
not enable in [production/untrusted]…"* (text truncated in the help
formatter — full caveat at upstream PR #18655). Treat it as **opt-in
per server**, not a default.

## Transport gap: stdio servers

Most "official" MCP servers (`@modelcontextprotocol/server-filesystem`,
`server-git`, `server-sqlite`, `server-time`, etc.) ship as **stdio**
processes. The browser cannot speak stdio. Two community bridges
preserve the MCP protocol:

- **`supergateway`** (Node, supercorp-ai) — wraps a stdio server and
  serves it over SSE/WebSocket. Closest match to "drop in front of any
  upstream MCP server." Recommended.
- **`mcp-proxy`** (Python) — lighter; same idea.

Avoid `mcpo` (Open WebUI's MCP→OpenAPI converter) for this use case —
it intentionally re-encodes MCP as OpenAPI, which loses prompt and
resource support and means the llama-server WebUI sees an OpenAPI
endpoint, not an MCP server.

Example stdio→Streamable-HTTP wrapper for the filesystem server,
sandboxed to the repo root. Three flags are non-obvious and all
required — discovered live during the 2026-05-25 smoke test (see
`benchmarks/mcp/2026-05-25-fs-smoke.md`):

```bash
npx -y supergateway \
  --stdio "npx -y @modelcontextprotocol/server-filesystem $PWD" \
  --outputTransport streamableHttp \
  --port 4001 \
  --cors http://127.0.0.1:10501
# then add http://127.0.0.1:4001/mcp  (not /sse) in the WebUI form
```

Gotchas if you hand-roll this:

- **Path ends in `/mcp`**, not `/sse`. The WebUI's "Add New Server"
  placeholder is misleading — it says `https://mcp.example.com/sse`
  but the client only speaks Streamable HTTP (`POST /mcp`). Connecting
  to an SSE-mode bridge yields `Cannot POST /sse`.
- **`--outputTransport streamableHttp` is not default.** Supergateway
  defaults to legacy SSE (`/sse` + `/message`) when given `--stdio`.
- **`--cors` is not default.** Without it the browser preflight fails
  with `No 'Access-Control-Allow-Origin' header`. Lock it to the
  llama-server origin; don't open `*` unless you mean to.

`scripts/mcp-bridge.sh` handles all three.

## Security / offline notes

Enabling `--ui-mcp-proxy` lets the llama-server backend make outbound
connections via its `/cors-proxy` endpoint. Observed live during the
2026-05-25 smoke test: with `MCP_PROXY=1`, the WebUI proxied a favicon
fetch to `https://www.google.com/s2/favicons` through llama-server —
visible in the server log as `proxy_request: proxying GET request to
https://www.google.com:443/...`. That's a real outbound connection, not
hypothetical. Breaks the repo's offline-clean guarantee
(`docs/offline-mode.md`, `SECURITY.md`) for any session with MCP on.
Treat it as an explicit opt-in:

- Off by default in all `scripts/start-*.sh`.
- Opt-in via `MCP_PROXY=1` env var, surfaced in `make` help and
  `docs/usage.md` with a one-line warning.
- `make audit-offline` should still pass when `MCP_PROXY` is unset
  (it does today — we just need a regression test once the flag is
  wired in).

## What to ship

1. **`scripts/_common.sh` helper** that emits `--ui-mcp-proxy` (or
   `--webui-mcp-proxy` on the turboquant fork — feature-detect via
   `--help | grep`) when `MCP_PROXY=1`. Mirrors `chat_template_flags`
   and `rope_args`.
2. **Wire-in** to `start-turboquant.sh`, `start-baseline.sh`,
   `start-qwen36-mtp.sh`. Off by default.
3. **Documented starter MCP set** in `docs/mcp-integration.md`
   (filesystem sandboxed to repo, git, sqlite if anyone uses it,
   time). One `supergateway` invocation per server.
4. **`scripts/mcp-bridge.sh <name>`** — convenience wrapper around
   `supergateway` for the documented starter set, with a sensible port
   allocation (4001+). Honors `MCP_PORT` override; refuses if port is
   busy.
5. **README + `docs/usage.md` notes** linking here.
6. **Verification**: after enabling, the WebUI's "Add New Server"
   accepts `http://127.0.0.1:4001/sse`, tools appear in the agentic
   loop, and the model emits a tool call that gets executed and
   reflected back.

## Quickstart (verified 2026-05-25)

```bash
# 1. Bring up llama-server with the CORS proxy on (off by default).
make stop                                  # stop the launchd primary
MCP_PROXY=1 ./scripts/start-turboquant.sh  # foreground; or background it

# 2. In another shell: start the filesystem bridge (port 4001).
make mcp-fs

# 3. Open http://127.0.0.1:10501/ in a browser.
#    Settings → MCP → Add New Server → http://127.0.0.1:4001/mcp
#    You should see "Connected in <2s · 14 tools available".

# 4. Ask the model to use a tool, e.g.
#    "List the files in the repository root directory. Use the filesystem tool."

# 5. Cleanup
#    Ctrl-C the bridge, kill the manual llama-server,
#    `launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.local.qwen3-6.turboquant.plist`
#    to restore the offline-default primary.
```

Smoke-test results recorded in `benchmarks/mcp/2026-05-25-fs-smoke.md`.

## Open questions / known risks

- **Tool-call quality on small models.** The Froggeric template fixes
  parsing, but a Q5_K_M dense 27B is not Claude. Expect to retry
  prompts and tighten system messages. Worth a calibration pass
  documented under a new `benchmarks/mcp/` directory once the wiring
  lands.
- **localStorage scope.** Switching browsers / private mode = empty
  server list. Acceptable for a single-user local box; document.
- **Mainline vs turboquant flag skew.** The turboquant fork only has
  the deprecated `--webui-mcp-proxy` because it was branched before
  the rename. Helper must feature-detect, not hardcode.
- **No support for sampling/elicitation.** Upstream discussion #22640
  flags that `llama-server` doesn't yet implement MCP **sampling**
  (server-initiated LLM calls back into the client). We can't
  participate in MCP-driven multi-agent loops, only consume tools /
  resources / prompts.
