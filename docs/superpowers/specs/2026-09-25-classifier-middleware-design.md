# Classifier Middleware Design — 2026-09-25

**Status:** Proposed replacement for the current JEV integration. No
`proxy/src/decide/` implementation is present in this revision.

## Context (legacy, to be replaced)
Legacy `proxy/src/jev.js` + hardcoded Q-sets in `rewrite.js`/`research.js`, gated by single URL/key, fail-open null. No unified interface, no chain, no kill-switch. This spec replaces all provider names with a generic decision chain.

## Contract (fixed in/out, provider-blind)
Input `DecideInput`: `{state: string|object|array, tasks: Record<name,{kind:select|score|flag, prompt?:string, options?:string[]|object}>, timeoutMs?:number, traceId?:string}`
Output `DecideOutput` (only shape callers ever see): `{status:ok|disabled|failed, results: Record<name,{kind, label?:string, score?:number, flag?:number, confidence?:number}>|null, source:string, latencyMs:number, trail:string[], error?:{code, message}}`
Rule: stages/providers normalize to this; callers only read this. `disabled/failed` → fail-open null-equivalent. Bad input throws `INVALID_INPUT` before chain.

## Chain = stages + providers (logic in between allowed)
`config.decide.chain: [{use:http|heuristic|llm|off, url?, timeout_ms?, allowTasks?:string[], when?:{} }]` ordered, first `ok` wins, else next. Any entry may also declare `before/after` hooks `(input)=>input` / `(output)=>output` — pure transforms for mapping, clamping, redacting — same in/out preserved.
Env: `DECIDE_DISABLED=1` > `DECIDE_CHAIN` (JSON) > `config.yaml`. Empty/all-`off` = disabled `{status:disabled,results:null}` ~0ms, zero I/O.
Per-request: `x-decide: off|force:<use>` header + `opts.use` param.

## Matching (per-situation select/skip)
1) task-allowlist: `allowTasks:[compact,relevance]` per entry — disjoint task sets hit different providers, else skip.
2) ctx-filter: `when:{prompt_token_fraction_gt,mode_in,has_tag,tool_name}` (hooks DSL subset) — sync metadata only.
3) per-request force: `x-decide` header — highest precedence.
4) confidence-gated continue: cheap provider first, `confidence<min` → next, trail records.
5) `use:off`: explicit skip → disabled, byte-identical.

## Approach (single, no provider names)
`proxy/src/decide/{types.js,chain.js,providers/*.js}` (~4 files, <250 LOC each). Legacy provider file archived, not referenced. `http` provider POSTs generic `{state,tasks}` (no fixed path/type names in contract); `heuristic/llm/off` are in-process. Interposed logic = `before/after` pure fns on fixed shapes.
`rewrite.js`/`research.js` → `decide(input)` → stages/providers → normalized output. Threshold mapping at caller unchanged. Byte-identical when disabled.
## Error handling / testing
Per-provider timeout (300ms rewrite, 6000ms research), AbortController, miss→next. All-fail → `{status:failed,error:ALL_FAILED}` + fail-open. Tests: contract vector (all providers same shape), order/fallback/timeout, disabled byte-identity, env precedence, 143 proxy tests green.

## Self-review
No TBD. Scope single plan (no new model servers). Ambiguity resolved: disabled = fail-open null-equivalent, not throw.
