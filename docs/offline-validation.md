# Offline-mode validation

The whole point: this stack must keep serving Qwen 3.6 with **no network**. Procedure to prove it.

## Procedure

```bash
# 1. Start TurboQuant server (or baseline)
./scripts/start-turboquant.sh &
sleep 30   # wait for warmup
./scripts/healthcheck.sh

# 2. Disable Wi-Fi
networksetup -setairportpower en0 off
# (optional) also disable Ethernet:
# networksetup -setnetworkserviceenabled "USB 10/100/1000 LAN" off

# 3. Run a real workload
./scripts/demo-chat.sh
# ask it something: "write a 50-line python http server"

# 4. Run the long-context check
./scripts/long-context-test.sh 10501 50000

# 5. Re-enable network
networksetup -setairportpower en0 on
```

## Pass criteria

- `/health` returns 200
- `demo-chat.sh` streams tokens normally
- `long-context-test.sh` recovers the needle
- Activity Monitor → Network → no traffic from `llama-server` while disconnected

## Failure modes seen offline

- **None expected** if the build is correct. llama.cpp loads the GGUF, opens a TCP socket on 127.0.0.1, no outbound calls anywhere.
- If you see DNS lookups: it's the client (e.g. OpenCode trying to fetch a remote MCP). The model itself is local-only.
- macOS Gatekeeper may quarantine the binary on first launch — run once while online so the kernel signs the cache, then flight-mode is safe forever after.

## Re-validate quarterly

LM Studio updates can move model files. After any LM Studio major version update:

```bash
./scripts/healthcheck.sh && echo "still good" || echo "model paths changed — fix scripts/_common.sh"
```
