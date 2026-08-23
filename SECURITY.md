# Security

The server is a local operator tool, not a network service. Every launcher
binds to `127.0.0.1` and passes `--cors-origins localhost`.

## Full runtime

The default enables llama.cpp `--agent`. Upstream defines that switch as the
combination of the WebUI MCP CORS proxy and all built-in tools, including shell
execution and file writes. Treat the model as a local process acting with your
user account's permissions:

- never bind it to `0.0.0.0`;
- never reverse-proxy it to another machine;
- review tool calls before accepting them in the WebUI;
- configure external MCP servers only from trusted local files;
- use `AGENT=0` for untrusted prompts or strict offline operation.

Agent mode can make outbound requests through the MCP proxy when a user or
tool asks it to. `make start-offline` disables that capability while leaving
the model, MTP, vision, reasoning, and metrics enabled.

## Model and dependency trust

Weights and the projector are not redistributed. `make model-link` links only
the documented Qwen3.8 artifacts. Engine revisions are exact SHAs in
`configs/upstream.env`; upgrades are accepted only after local build and live
validation.

Report project vulnerabilities privately to the repository owner. Report
llama.cpp or TurboQuant engine vulnerabilities to their upstream projects.
