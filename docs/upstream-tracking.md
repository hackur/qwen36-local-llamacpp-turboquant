# Upstream tracking

Exact accepted revisions live in `configs/upstream.env`. Branch tips are not
runtime dependencies until this machine builds and validates them.

## Acceptance policy

1. Review changes since the current pin from the primary GitHub repositories.
2. Pay particular attention to Qwen3.8, MTP, Metal, projector, server tools,
   MCP, reasoning, and memory changes.
3. Run `make upgrade` to fetch branch tips and rebuild both engines.
4. Run `make preflight`, `make check`, `make proxy-test`, then live text,
   vision, tools, metrics, and context validation.
5. Record exact SHAs and results before changing `configs/upstream.env`.

The active TurboQuant branch is moving again, but current does not automatically
mean safer. Issue #308 reports increased Qwen3.8 VRAM use on newer builds. Pins
therefore move only when the full 262K Metal profile still fits and behaves.

Mainline exists as a same-artifact control. TurboQuant is the production engine
because the project depends on turbo3 V cache and the fork's adaptive/chained
MTP implementation.
