# Local model and agent harness

This repository records local model operation across past, current and future
models: engine pins and licenses, artifact provenance, runtime flags, lifecycle,
proxy/classifier behavior, browser tools, tests and handoff evidence. Each
profile must describe reasoning, context, GPU memory, tool and vision support
and limitations. A classifier being available does not authorize routing.
The proxy remains in shadow mode; optional enforcement remains opt-in.

## Common model entry point

```bash
python3 scripts/models.py list
python3 scripts/models.py start lfm3-1.7b --dry-run
python3 scripts/models.py start lfm3-1.7b
# Ctrl+C unloads this foreground run before starting another model:
python3 scripts/models.py start crow-9b
python3 scripts/models.py start qwen38 --dry-run
```

Profiles: qwen38, lfm3-1.7b, crow-9b, mimo-9b, journalist-9b.
This normalizes invocation, not the binaries. Qwen38 delegates to the existing
TurboQuant launcher and its primary configuration (:10501); other models use
the independent experimental launcher (:10502). Do not launch a second Qwen
copy while the login service owns it. Use make service-status first and
coordinate any downtime. No switch or test here stops an existing service.
For already managed Qwen, use the existing service controls. Legacy make switch
explicitly stops the primary stack; it is not the non-disruptive experiment path.

## Browser route: OpenClaw gateway

Use the locally installed openclaw-gateway skill. The inspected skill's command
reference predates the installed CLI; CLI --help is authoritative for flags.
On 2026-11-04 installed OpenClaw reported 2026.9.7 and gateway health succeeded.
Its health report also reported an old delivery-queue warning; no repair or
message delivery was attempted. Use the configured gateway, not a hardcoded
port from the older skill (which describes port 18999).

```bash
openclaw health
openclaw browser --help
openclaw browser --browser-profile <profile> start
openclaw browser --browser-profile <profile> open https://example.com
openclaw browser snapshot --target-id <tab-id> --efficient
openclaw browser click <fresh-ref>
openclaw browser snapshot --target-id <tab-id> --efficient
```

Use an explicit profile and tab throughout multi-tab work; pass --target-id
where supported (verify each command's help). Refs are ephemeral. Navigation,
clicking, typing, forms, evaluation, downloads and screenshots are supported
by the gateway; permission for sensitive actions still comes from the user.
A browser tool requires an executing host tool loop. The local model emitting
a tool call does not itself execute it; experimental text servers do not
implicitly gain browser or shell tools. Do not auto-run openclaw agent, select
a hosted provider, or activate model/classifier routing just because it exists.
Keep existing tools available as explicit fallbacks and explain gateway failures.
The CLI route may reduce transcript overhead, but no token savings are claimed.

## Complete collection and larger-model handoffs

Efficient snapshots help navigation. They are bounded (installed defaults are
500/800 nodes), and interactive-only/depth/selector filters omit content.
Capture the substantive page and each needed pagination/frame/API surface.
For a rendered DOM capture with the chosen tab:

```bash
mkdir -p data/captures
openclaw browser --json evaluate --target-id <tab-id> \
  --fn '() => ({url:location.href,title:document.title,capturedAt:new Date().toISOString(),html:document.documentElement.outerHTML})' \
  > data/captures/page.json
python3 scripts/collect-source.py data/captures/page.json \
  --format json --url https://example.com \
  --capture-note 'Rendered DOM; pagination and frames checked separately'
```

Archive CLI errors separately; verify the JSON result contains the intended
HTML. The collector understands JSON strings or result/html envelopes; unknown
JSON is retained as readable JSON rather than guessed. Plain saved HTML or
text can be imported using --format html or text. It never fetches or evaluates
source content, changes browser settings, or overwrites an existing bundle.

Each ignored data/collections bundle contains source.bin (exact supplied
bytes), readable.txt (complete derived view), manifest.json (requested/captured URLs, capture time when supplied, archive time,
SHA-256, byte/character counts, capture coverage and truncation), and handoff.md
(a bounded excerpt with explicit counts and retrieval paths). --max-chars sets
the excerpt budget; --source-truncated records an already limited capture.
Script/style code is excluded from HTML's readable view; structured JSON-LD
and links remain. Raw markup is preserved for checking formatting or extraction
losses. The collector cannot recover omitted browser data or authenticate a
source URL; capture notes must state actual coverage and collection method.

Before handing work to a larger model, include task, question, constraints,
findings, uncertainties, manifest references and explicit missing/truncated
surfaces. Retrieve omitted readable/source files in chunks when needed. Do not
paste executable page code or repeat boilerplate into the model context.
Keep disagreements, tables, values and provenance rather than only a summary.
These local archives may be sensitive: ignored data is not published by Git.
Review/redact deliberately before transmitting evidence to any external model.

The old proxy/scripts/research.mjs workflow remains an explicit bounded search
and synthesis helper. Its 8000-character fetch preview and ranking/synthesis
budgets are not complete collection; oversized fetches now warn and carry a
truncation marker. Use archived browser captures for thorough handoffs.

See [engine normalization](engine-normalization.md) for current source revisions, upstream/fork differences, validation limits and rollback.
