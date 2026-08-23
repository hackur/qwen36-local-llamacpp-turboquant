# Offline validation procedure

1. `make stop`
2. Disable Wi-Fi and disconnect other interfaces if proving air-gap behavior.
3. `AGENT=0 make start-foreground`
4. In another terminal, run `make quality`, `make vision`, and
   `make audit-offline`.
5. Confirm `/health`, `/v1/models`, `/metrics`, text generation, and vision all
   succeed without a non-loopback socket.

Do not run the proof with `--agent`; its MCP proxy is designed to make outbound
requests when directed.
