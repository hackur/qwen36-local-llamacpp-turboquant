# Agent tools and MCP

The accepted TurboQuant server already implements the pieces this project used
to emulate with supergateway bridges:

- `--agent`: WebUI MCP proxy plus all built-in tools;
- `--tools`: selective built-in tool enablement;
- `--mcp-servers-config`: Cursor-compatible stdio MCP configuration;
- `--mcp-servers-json`: equivalent inline configuration.

The default uses `--agent`. Built-in tools include file read/search, shell,
write/edit, datetime, and system info. This is powerful and intentionally
restricted to localhost.

To attach external stdio servers directly:

```json
{
  "mcpServers": {
    "example": {
      "command": "/absolute/path/to/server",
      "args": ["--stdio"]
    }
  }
}
```

```bash
MCP_CONFIG=/absolute/path/mcp.json make start-foreground
```

The server discovers MCP tools during startup and exposes them through its
native `/tools` endpoint and WebUI. No bridge ports, CORS sidecars, or npx
wrappers are part of this repository anymore.

Agent/MCP mode is not strictly offline. Use `make start-offline` for untrusted
content or a network-isolation proof.

Source: [TurboQuant server documentation](https://github.com/TheTom/llama-cpp-turboquant/blob/feature/turboquant-kv-cache/tools/server/README.md#built-in-tools-support).
