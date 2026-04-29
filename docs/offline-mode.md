# Running fully offline — and why LM Studio breaks

Goal: chat with Qwen 3.6 with **Wi-Fi off, Ethernet unplugged, in a Faraday cage** — and have it just work.

## Why LM Studio fails when you disconnect

LM Studio is great for downloading models and exploring. It is **not** designed for fully-offline operation. From inspecting `~/.lmstudio/.internal/`:

- `lm-link-account-status-cache.json` holds an account-status snapshot (`accountStatus`, `maxDevicesAllowed`, etc.). When the cache TTL expires the app re-checks online; offline → check fails → UI may block features.
- `model-index-cache.json` is the cached hub catalog. The app refreshes it on launch; offline → "couldn't load catalog" banner.
- The Electron UI itself does telemetry / update checks at startup.

Even with `forceDisabled: true` in `lm-link-config.json`, the app is built around being-online by default, and the failure mode at startup is opaque to the user.

## Why this stack doesn't have any of those problems

`llama-server` is a single C++ binary that:

1. mmap-loads the GGUF from disk
2. binds `127.0.0.1:10501`
3. serves OpenAI-compatible HTTP

That's it. **Empirically verified** — `lsof` on the running process before and after multiple generations:

```
$ lsof -nP -p $(pgrep -f vendor/llama-cpp-turboquant.*llama-server) | grep -E "TCP|UDP"
llama-ser 51886 user   3u  IPv4 ...  TCP 127.0.0.1:10501 (LISTEN)
```

One socket. localhost. Read-only model file. **No outbound. No DNS. No telemetry. No license check.**

## Offline-survival recipe

### One-time, while online

```bash
# Build (uses brew & xcode, both already installed)
./scripts/build-llama.sh

# Symlink models from LM Studio's directory (no copy)
./scripts/symlink-models.sh

# Smoke test
./scripts/start-turboquant.sh &
./scripts/healthcheck.sh
pkill -f vendor/llama-cpp-turboquant
```

### Forever, offline

```bash
# Start the server
./scripts/start-turboquant.sh &

# Talk to it (any of these work offline)
open clients/web-demo.html              # browser UI, no internet needed
PORT=10501 ./scripts/demo-chat.sh        # terminal REPL
python3 clients/python-demo.py "hello"   # Python client (openai SDK, localhost only)
```

To make it act like an "app" — see `Qwen-Offline.command` (double-click launcher).

### One-shot offline test

```bash
# Confirm the server has no outbound sockets
PID=$(pgrep -f vendor/llama-cpp-turboquant.*llama-server)
lsof -nP -p "$PID" | grep -E "TCP|UDP" | grep -v 127.0.0.1
# expect: empty (no non-localhost sockets)
```

Or, the brute-force test — turn off Wi-Fi:

```bash
networksetup -setairportpower en0 off
./scripts/healthcheck.sh && open clients/web-demo.html
networksetup -setairportpower en0 on
```

## Things that DO need network (do them while online)

- **First build** — clones llama.cpp from GitHub. Done once.
- **Model download** — done in LM Studio, or via `huggingface-cli`. Done once per model.
- **Editor extensions** — Continue / OpenCode / Zed installation pulls from npm/pypi. Once installed, they work offline against localhost.

> **Note:** `clients/python-demo.py` uses **only stdlib** (`urllib.request`) — no `pip install openai` needed. Same for `scripts/bench.py`, `scripts/needle.py`, `scripts/mini-eval.py`.

After that initial setup, you can stay offline indefinitely. The model file, the binaries, and the demos are all on disk.

## Things that do NOT need network even on first run

- `clients/web-demo.html` — single file, no CDN imports, opens with `open` from a `file://` URL.
- `scripts/demo-chat.sh` — pure curl + jq + bash, all preinstalled on macOS.
- `scripts/healthcheck.sh`, `scripts/benchmark.sh`, etc. — same.

## If something goes wrong offline

| Symptom | Cause | Fix |
|---|---|---|
| `start-turboquant.sh` hangs at "loading model" | macOS Gatekeeper quarantining the binary on first run | Run once while online so kernel signs the cache, then offline forever |
| `Address already in use` on :10501 | leftover server, or LM Studio's own server on :1234 collided | `./scripts/stop-all.sh` |
| Model file path doesn't exist | LM Studio update moved it | Re-run `./scripts/symlink-models.sh`; if still bad, edit `scripts/_common.sh` |
| `llama-server` exits immediately | OOM (another server still running with weights on GPU) | `./scripts/stop-all.sh` then start again |
| Python demo: `ModuleNotFoundError: openai` | not installed | go online once: `pip3 install openai` |
| Web demo: blank page | unrelated to network — open dev tools, look at console | usually a typo in the port selector |

## Replacing LM Studio entirely

You don't have to delete LM Studio — it's still useful for browsing the hub when you're online. But for inference, **stop using it** and use this stack instead. Your model files in `~/.lmstudio/models/` are shared (we symlink, not copy), so the disk footprint is unchanged.

To make our stack auto-start at login (so it's always there when you need it offline):

```bash
sed "s|__REPO__|$(pwd)|g" configs/launchd-plist.template \
  > ~/Library/LaunchAgents/com.local.qwen3-6.turboquant.plist
launchctl load ~/Library/LaunchAgents/com.local.qwen3-6.turboquant.plist
```

After this, `http://127.0.0.1:10501` is always live, with or without Wi-Fi.
