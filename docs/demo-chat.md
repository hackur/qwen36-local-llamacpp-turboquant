# Terminal chat REPL — `make demo`

Streaming chat client for the local llama-server. Stdlib Python, no dependencies. The wrapper script `scripts/demo-chat.sh` is a thin shim around `scripts/demo-chat.py`; both accept the same flags.

## Quick start

```bash
make demo                                 # default: thinking off, port from $PORT or 10501
./scripts/demo-chat.sh                    # same thing, bash-friendly
python3 scripts/demo-chat.py --think on   # show the model's reasoning trace
```

End the session with `Ctrl-D` at an empty prompt or type `/quit`. `Ctrl-C` during a streaming reply cancels just that reply and returns you to the prompt — it does not exit.

## CLI flags

| Flag | Default | Meaning |
|---|---|---|
| `--port N` | `$PORT` or `10501` | TCP port of the llama-server |
| `--think on\|off\|auto` | `off` (or `on` if `THINK=1`) | Set `chat_template_kwargs.enable_thinking`. `auto` omits the field and lets the server template decide. |
| `--max-history-chars N` | `200000` | Approx character budget (~50K tokens). Oldest non-system pairs are dropped when exceeded. |
| `--system "..."` | none | Seed the conversation with a system message. |

Flags override env vars. The env vars (`PORT`, `THINK`) are kept for back-compat with the prior bash REPL.

## Slash commands

| Command | Effect |
|---|---|
| `/help` | Print available commands |
| `/reset` | Clear conversation history |
| `/think on\|off\|toggle` | Change thinking mode for subsequent turns |
| `/save PATH` | Write history (incl. reasoning) to PATH as JSON |
| `/load PATH` | Replace history with the contents of PATH |
| `/history` | Print message count and rough char total |
| `/quit` | Exit cleanly (also Ctrl-D) |

Anything starting with `/` that isn't a known command is sent to the model verbatim.

## Thinking output

When `--think on` (or `auto` with a thinking template), the model emits reasoning **before** the final answer. The REPL surfaces both:

- Reasoning streams **dimmed**, prefixed with `[thinking] ` once at the start.
- When the final answer begins, the dim color is closed and a blank line separates the two.
- Reasoning is preserved in `/save` output but is **not** replayed back to the server (the server reconstructs its own thinking based on `content` only).

This is the main behavior the bash version got wrong — it dropped `delta.reasoning_content` entirely, which made thinking turns look like a long pause followed by garbled text.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Clean exit (Ctrl-D, `/quit`, or end of piped stdin) |
| `1` | Could not reach the server on startup |
| `2` | Protocol error — malformed SSE we couldn't recover from |

## Troubleshooting

**Connection refused on startup** — server isn't running. `make start` first, or check `make status`.

**Reply looks like one giant line of text** — your terminal probably doesn't grok ANSI. Pipe through `less -R`, or run with `TERM=dumb` to disable colors (the REPL detects non-TTY stdout and skips ANSI).

**Nothing prints for a long time, then a wall of text** — model is in thinking mode but you launched with `--think off`. Either the server template is forcing thinking, or you want `--think on` to see it stream live.

### Why was the old `demo-chat.sh` broken?

The bash version had three real bugs that the Python rewrite fixes:

1. **Thinking output was invisible.** The bash reader only inspected `delta.content` and silently dropped `delta.reasoning_content`. When the server emits reasoning (Qwen 3.6 with `--jinja` does), there was nothing to show until the final answer arrived. The Python version surfaces both deltas as separate event kinds and renders reasoning dimmed with a `[thinking] ` prefix.
2. **Markdown lists collapsed onto one line.** Streamed chunks occasionally carry stray C0 control bytes that corrupt terminal rendering — cursor-move, erase-line, the works. The Python version sanitizes every chunk with a regex that strips `\x00–\x1F` except `\t`, `\n`, `\r`.
3. **Phantom `qwen>` reply on bare Enter.** Whitespace-only input was being POSTed to the server, which dutifully replied with whatever it does for empty user turns. The Python version filters empty/whitespace input before making any request.

## Testing

```bash
python3 -m unittest discover -s tests
```

33 tests, runs in about 1 second, no llama-server required. Wired into `make check`.
