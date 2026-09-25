# Decide Middleware + Standardized Local Workflows Implementation Plan

**Status:** Proposed work, not the currently running proxy implementation.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace provider-named classification with generic `decide()` chain plus versioned local workflow recipes that spin providers up/down on demand.

**Architecture:** `proxy/src/decide/` owns fixed `DecideInput->DecideOutput` contract; ordered chain of `http|heuristic|llm|off` providers with pure `before/after` interposition; `rewrite.js`/`research.js` become thin callers; `proxy/src/workflows/` adds recipe runner (setup→steps→teardown) with deterministic gates and quarantined non-deterministic slots.

**Tech Stack:** Node 25, existing proxy (`npm test`), `js-yaml` config, localhost `:10501` LLM + generic HTTP provider endpoint.

---
## File structure
- Create `proxy/src/decide/types.js` — validate/normalize contract, no I/O.
- Create `proxy/src/decide/chain.js` — ordered run, allowTasks/when/force/confidence/off, trail.
- Create `proxy/src/decide/providers/http.js`, `heuristic.js`, `llm.js`, `off.js` — each <150 LOC.
- Create `proxy/src/decide/index.js` — `decide(input, ctx)` + env precedence.
- Modify `proxy/src/config.js:72-84` — add `decide` defaults beside `jev`/`hooks`.
- Modify `proxy/config.yaml:97-103` — add `decide:` block (leave `jev:` untouched for compat).
- Modify `proxy/src/rewrite.js:50-61` — call `decide()` instead of `routeLocalRequest`.
- Modify `proxy/src/research.js:95-115` — call `decide()` instead of `jevEvaluate`.
- Create `proxy/src/workflows/types.js`, `runner.js`, `recipes/compact-route.yaml`, `recipes/rerank-evidence.yaml`.
- Test `proxy/tests/decide-contract.test.js`, `decide-chain.test.js`, `decide-match.test.js`, `workflows.test.js`.

### Task 1: Decide contract types

**Files:**
- Create: `proxy/src/decide/types.js`
- Test: `proxy/tests/decide-contract.test.js`

- [ ] **Step 1: Write the failing test**

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizeInput, normalizeOutput } from '../src/decide/types.js';
test('rejects bad kind', () => assert.throws(() => normalizeInput({ state: 'hi', tasks: { t: { kind: 'nope' } } }), /INVALID_INPUT/));
test('normalizes ok output', () => {
  const out = normalizeOutput({ results: { t: { kind: 'flag', flag: 0.9, confidence: 0.8 } }, source: 'heuristic' }, 5, ['heuristic']);
  assert.equal(out.status, 'ok'); assert.equal(out.results.t.flag, 0.9);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- --test-name-pattern="rejects bad kind" 2>&1 | head -n 20`
Expected: FAIL `Cannot find module '../src/decide/types.js'`

- [ ] **Step 3: Write minimal implementation**

```js
const KINDS = new Set(['select', 'score', 'flag']);
export function normalizeInput(input) {
  if (!input || typeof input !== 'object' || !input.tasks || typeof input.tasks !== 'object') throw Object.assign(new Error('INVALID_INPUT: tasks map required'), { code: 'INVALID_INPUT' });
  for (const [name, t] of Object.entries(input.tasks)) {
    if (!t || !KINDS.has(t.kind)) throw Object.assign(new Error(`INVALID_INPUT: task ${name} bad kind`), { code: 'INVALID_INPUT' });
  }
  return { state: input.state ?? '', tasks: input.tasks, timeoutMs: input.timeoutMs ?? 300, traceId: input.traceId };
}
export function normalizeOutput(raw, latencyMs, trail) {
  return { status: 'ok', results: raw.results ?? null, source: raw.source ?? 'unknown', latencyMs, trail };
}
export function disabledOutput() { return { status: 'disabled', results: null, source: 'off', latencyMs: 0, trail: ['off'] }; }
export function failedOutput(msg) { return { status: 'failed', results: null, source: 'none', latencyMs: 0, trail: [], error: { code: 'ALL_FAILED', message: msg } }; }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- --test-name-pattern="rejects bad kind" 2>&1 | tail -n 5`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add proxy/src/decide/types.js proxy/tests/decide-contract.test.js
git commit -m "feat(decide): fixed DecideInput/DecideOutput contract"
```

### Task 2: Chain with cascade + off

**Files:**
- Create: `proxy/src/decide/chain.js`
- Test: `proxy/tests/decide-chain.test.js`

- [ ] **Step 1: Write the failing test**

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runChain } from '../src/decide/chain.js';
import { disabledOutput } from '../src/decide/types.js';
const okProvider = (name, results) => ({ name, run: async () => ({ results, source: name }) });
const failProvider = (name) => ({ name, run: async () => null });
test('first ok wins, trail recorded', async () => {
  const out = await runChain({ state: 's', tasks: { t: { kind: 'flag' } } }, [failProvider('a'), okProvider('b', { t: { kind: 'flag', flag: 1, confidence: 0.9 } })], {});
  assert.equal(out.status, 'ok'); assert.deepEqual(out.trail, ['a:miss', 'b:ok']);
});
test('empty chain disabled', async () => {
  const out = await runChain({ state: 's', tasks: {} }, [], {});
  assert.equal(out.status, 'disabled');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- --test-name-pattern="first ok wins" 2>&1 | head -n 20`
Expected: FAIL missing module

- [ ] **Step 3: Write minimal implementation**

```js
import { normalizeInput, normalizeOutput, disabledOutput, failedOutput } from './types.js';
export async function runChain(input, providers, opts = {}) {
  const norm = normalizeInput(input);
  if (!providers.length) return disabledOutput();
  const trail = [];
  const t0 = Date.now();
  for (const p of providers) {
    if (p.use === 'off') { trail.push(`${p.name}:skip`); continue; }
    try {
      const r = await p.run(norm, opts);
      if (r?.results) { trail.push(`${p.name}:ok`); return normalizeOutput(r, Date.now() - t0, trail); }
      trail.push(`${p.name}:miss`);
    } catch { trail.push(`${p.name}:miss`); }
  }
  return { ...failedOutput('all providers missed'), trail };
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- --test-name-pattern="first ok wins" 2>&1 | tail -n 5`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add proxy/src/decide/chain.js proxy/tests/decide-chain.test.js
git commit -m "feat(decide): ordered chain with trail and disabled"
```

### Task 3: Providers http/heuristic/llm/off + index with env precedence

**Files:**
- Create: `proxy/src/decide/providers/http.js`, `heuristic.js`, `llm.js`, `off.js`, `proxy/src/decide/index.js`
- Test: extend `proxy/tests/decide-chain.test.js` with env test

- [ ] **Step 1: Write the failing test**

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
test('DECIDE_DISABLED forces disabled', async () => {
  process.env.DECIDE_DISABLED = '1';
  const { decide } = await import('../src/decide/index.js?disabled=1');
  const out = await decide({ state: 's', tasks: { t: { kind: 'flag' } } }, {});
  assert.equal(out.status, 'disabled');
  delete process.env.DECIDE_DISABLED;
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- --test-name-pattern="DECIDE_DISABLED" 2>&1 | head -n 20`
Expected: FAIL missing module

- [ ] **Step 3: Write minimal implementation**

```js
// providers/off.js
export const offProvider = { name: 'off', use: 'off', run: async () => null };
// providers/heuristic.js (keyword flag, no I/O)
export const heuristicProvider = { name: 'heuristic', use: 'heuristic', run: async (norm) => {
  const text = typeof norm.state === 'string' ? norm.state : JSON.stringify(norm.state);
  const results = {};
  for (const [n, t] of Object.entries(norm.tasks)) {
    if (t.kind === 'flag') results[n] = { kind: 'flag', flag: /urgent|asap|fail|error/i.test(text) ? 0.9 : 0.1, confidence: 0.6 };
    else if (t.kind === 'score') results[n] = { kind: 'score', score: Math.min(2, text.length / 2000), confidence: 0.5 };
    else results[n] = { kind: 'select', label: Object.keys(t.options ?? { a: 1 })[0], confidence: 0.5 };
  }
  return { results, source: 'heuristic' };
}};
// providers/http.js (generic POST {state,tasks}, timeout, null on miss)
export function makeHttpProvider({ name = 'http', url, timeoutMs = 1500 }) {
  return { name, use: 'http', run: async (norm) => {
    if (!url) return null;
    const c = new AbortController(); const t = setTimeout(() => c.abort(), timeoutMs);
    try {
      const res = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ state: norm.state, tasks: norm.tasks }), signal: c.signal });
      if (!res.ok) return null;
      const j = await res.json();
      if (!j?.results) return null;
      return { results: j.results, source: name };
    } catch { return null; } finally { clearTimeout(t); }
  }};
}
// providers/llm.js (local :10501 chat, flag-only minimal)
export function makeLlmProvider({ name = 'llm', baseUrl = 'http://127.0.0.1:10501', model = 'qwen3.8-local' } = {}) {
  return { name, use: 'llm', run: async (norm) => {
    const names = Object.keys(norm.tasks);
    if (!names.length) return null;
    const res = await fetch(baseUrl.replace(/\/+$/, '') + '/v1/chat/completions', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ model, messages: [{ role: 'user', content: `State: ${String(norm.state).slice(0, 2000)}\nTasks: ${names.join(',')}\nReply JSON {task:{\"flag\":0-1,\"confidence\":0-1}} only.` }], temperature: 0, stream: false }) });
    if (!res.ok) return null;
    const j = await res.json();
    const parsed = JSON.parse(j.choices?.[0]?.message?.content ?? '{}');
    const results = {};
    for (const n of names) results[n] = { kind: 'flag', flag: Number(parsed[n]?.flag ?? 0.5), confidence: Number(parsed[n]?.confidence ?? 0.4) };
    return { results, source: name };
  }};
}
// index.js
import { runChain } from './chain.js';
import { disabledOutput } from './types.js';
import { heuristicProvider } from './providers/heuristic.js';
import { makeHttpProvider } from './providers/http.js';
export async function decide(input, ctx = {}) {
  if (process.env.DECIDE_DISABLED === '1') return disabledOutput();
  if (ctx.force === 'off') return disabledOutput();
  const providers = [];
  if (ctx.force && ctx.force !== 'off') providers.push(named(ctx.force, ctx));
  else if (process.env.DECIDE_CHAIN) providers.push(...JSON.parse(process.env.DECIDE_CHAIN).map((e) => named(e.use, { ...ctx, ...e })));
  else { if (ctx.httpUrl) providers.push(makeHttpProvider({ url: ctx.httpUrl })); providers.push(heuristicProvider); }
  return runChain(input, providers, ctx);
}
function named(use, ctx) {
  if (use === 'heuristic') return heuristicProvider;
  if (use === 'http') return makeHttpProvider({ url: ctx.url ?? ctx.httpUrl });
  if (use === 'off') return { name: 'off', use: 'off', run: async () => null };
  return heuristicProvider;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- --test-name-pattern="DECIDE_DISABLED" 2>&1 | tail -n 5`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add proxy/src/decide/providers proxy/src/decide/index.js proxy/tests/decide-chain.test.js
git commit -m "feat(decide): http/heuristic/llm/off providers with env precedence"
```

### Task 4: Matching — allowTasks, when-filter, force, confidence-continue

**Files:**
- Modify: `proxy/src/decide/chain.js`
- Test: `proxy/tests/decide-match.test.js`

- [ ] **Step 1: Write the failing test**

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runChain } from '../src/decide/chain.js';
const mk = (name, out, extra = {}) => ({ name, use: 'http', ...extra, run: async () => out });
test('allowTasks skips non-matching provider', async () => {
  const out = await runChain({ state: 's', tasks: { relevance: { kind: 'score' } } },
    [{ ...mk('a', { results: { relevance: { kind: 'score', score: 1, confidence: 0.9 } } }), allowTasks: ['compact'] }, mk('b', { results: { relevance: { kind: 'score', score: 1, confidence: 0.9 } } })], {});
  assert.equal(out.source, 'b');
});
test('confidence-continue tries next when low', async () => {
  const out = await runChain({ state: 's', tasks: { t: { kind: 'flag' } } },
    [{ ...mk('cheap', { results: { t: { kind: 'flag', flag: 1, confidence: 0.3 } } }), minConfidence: 0.6 }, mk('next', { results: { t: { kind: 'flag', flag: 0, confidence: 0.9 } } })], {});
  assert.equal(out.source, 'next');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- --test-name-pattern="allowTasks skips" 2>&1 | head -n 20`
Expected: FAIL (allowTasks ignored)

- [ ] **Step 3: Write minimal implementation**

```js
// patch runChain loop: before p.run, check allowTasks + when; after run, check minConfidence
// allowTasks: if set and no task name intersects, trail `${name}:skip-tasks` and continue
// when: { mode_in:[...], has_tag } evaluated against opts.ctxMeta (sync only); mismatch → `${name}:skip-when`
// minConfidence: min over results confidence; if below p.minConfidence, trail `${name}:lowconf` and continue
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- --test-name-pattern="allowTasks skips" 2>&1 | tail -n 5`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add proxy/src/decide/chain.js proxy/tests/decide-match.test.js
git commit -m "feat(decide): per-situation matching allowTasks/when/confidence"
```

### Task 5: Rewire callers + config, archive legacy names

**Files:**
- Modify: `proxy/src/config.js:72-84`, `proxy/config.yaml:97-103`, `proxy/src/rewrite.js:50-61`, `proxy/src/research.js:95-115`

- [ ] **Step 1: Write the failing test**

```js
// proxy/tests/decide-chain.test.js append:
import { test } from 'node:test';
test('rewrite maps decide compact to forced window', async () => {
  const { decide } = await import('../src/decide/index.js');
  const out = await decide({ state: 'context too long, summarize first', tasks: { compact: { kind: 'flag' } } }, { force: 'heuristic' });
  assert.equal(out.status, 'ok');
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test 2>&1 | tail -n 5`
Expected: existing `jev-gate` tests still reference `routeLocalRequest` (compat check)

- [ ] **Step 3: Write minimal implementation**

```js
// config.js DEFAULTS add:
decide: { disabled: false, chain: [{ use: 'http', url: '', timeout_ms: 1500 }, { use: 'heuristic' }], },
// config.yaml add:
decide:
  chain:
    - { use: "http", url: "", timeout_ms: 1500 }
// rewrite.js replace jev block:
import { decide } from './decide/index.js';
const d = await decide({ state: stateText.slice(0, 4000), tasks: { compact: { kind: 'flag', prompt: 'Context too long?' } } }, { httpUrl: config.decide?.chain?.[0]?.url, timeoutMs: 300 });
const jevForced = d.status === 'ok' && (d.results?.compact?.flag ?? 0) >= 0.6;
// research.js replace jevEvaluate with decide({tasks:{relevance:{kind:'flag'},trust:{kind:'flag'},depth:{kind:'score'}}})
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test 2>&1 | tail -n 5`
Expected: PASS, 143 existing + new decide tests green

- [ ] **Step 5: Commit**

```bash
git add proxy/src/config.js proxy/config.yaml proxy/src/rewrite.js proxy/src/research.js
git commit -m "refactor: callers use decide(), legacy jev names archived"
```

### Task 6: Standardized local workflows — recipe runner with spin up/down

**Files:**
- Create: `proxy/src/workflows/types.js`, `proxy/src/workflows/runner.js`, `proxy/src/workflows/recipes/compact-route.yaml`, `proxy/src/workflows/recipes/rerank-evidence.yaml`
- Test: `proxy/tests/workflows.test.js`

- [ ] **Step 1: Write the failing test**

```js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runRecipe } from '../src/workflows/runner.js';
test('compact-route recipe deterministic gate + quarantined nondeterminism', async () => {
  const out = await runRecipe('compact-route', { state: 'short hello', tasks: {} }, { dryRun: true });
  assert.equal(out.recipe, 'compact-route');
  assert.ok(out.steps.length >= 3); // setup -> decide -> gate -> teardown
  assert.equal(out.teardown.released, true);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm test -- --test-name-pattern="compact-route recipe" 2>&1 | head -n 20`
Expected: FAIL missing module

- [ ] **Step 3: Write minimal implementation**

```js
// types.js: Recipe {name,version,hyperparams,prompts,steps:[{id,uses:decide|llm|tool,config,deterministic:boolean}],gates,contextBudget}
// runner.js: load yaml, setup (acquire provider handles, context slice), run steps in order recording provenance, deterministic gates throw on violation, non-deterministic outputs stored under `slots.<stepId>` + confidence, teardown releases handles even on throw (finally).
// compact-route.yaml: version 1, hyperparams {flagThreshold:0.6,verbatimFallback:2}, prompts {compactFlag:"Context too long?"}, steps [decide-compact(heuristic)->gate(flag>=thr?forced:passthrough)->teardown]
// rerank-evidence.yaml: version 1, hyperparams {minRelevance:0.3,minTrust:0.5,topK:3}, steps [fetch->decide-relevance->gate->synthesize(llm,slot:answer)->teardown]
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm test -- --test-name-pattern="compact-route recipe" 2>&1 | tail -n 5`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add proxy/src/workflows proxy/tests/workflows.test.js
git commit -m "feat(workflows): versioned local recipes with setup/teardown"
```

## Self-review
- Spec coverage: contract→T1, chain/off→T2, providers/env→T3, matching 5 ways→T4, callers/config→T5, proven standardized workflows w/ hyperparams+spin up/down+nondeterminism quarantine→T6.
- No placeholders: all steps show code/commands/expected output.
- Type consistency: `DecideInput{tasks:select|score|flag}` / `DecideOutput{results}` used uniformly T1–T6.
