# Agent tools and MCP

The accepted TurboQuant server already implements the pieces this project used
to emulate with supergateway bridges:

- `--agent`: WebUI MCP proxy plus all built-in tools;
- `--tools`: selective built-in tool enablement;
- `--mcp-servers-config`: Cursor-compatible stdio MCP configuration;
- `--mcp-servers-json`: equivalent inline configuration.

The default uses `--agent`. The pinned fork lists eight built-in tools:
`read_file`, `file_glob_search`, `grep_search`, `exec_shell_command`,
`write_file`, `edit_file`, `get_datetime`, and `get_info`. The WebUI MCP CORS
proxy is a browser feature. It is separate from the optional Node context
compaction proxy on `:11500`.

Agent mode makes these tools available; the model does not call all of them
on every turn. `GET /tools` shows what the running server currently exposes.
External stdio MCP tools appear only when `MCP_CONFIG` points to a readable
configuration. API clients supplying their own `tools` definitions manage
their own tool-call loop.

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
