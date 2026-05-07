// Hook engine + built-in handler tests (docs/hooks-middleware.md v0.2 MVP).
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

import { createEngine, createContext } from "../src/hooks/engine.js";
import { resolveHandler, listBuiltinIds } from "../src/hooks/registry.js";
import { handler as tagBashRead } from "../src/hooks/tag-bash-read-elisions.js";
import { handler as ctxPressure } from "../src/hooks/context-pressure-reminder.js";
import { handler as oncePerSession, _resetForTests as resetOnce } from "../src/hooks/once-per-session.js";
import { handler as sessionHintLoader } from "../src/hooks/session-hint-loader.js";
import { handler as proseSummarize } from "../src/hooks/prose-summarize.js";

// ---- engine ----

test("engine: hasHooksFor false on empty registry", () => {
  const e = createEngine();
  assert.equal(e.hasHooksFor("request:received"), false);
});

test("engine: priority order + later hooks see earlier mutations", async () => {
  const e = createEngine();
  const seq = [];
  e.register("request:received", {
    id: "a", priority: 50,
    handler: (c) => { c.tag("a"); seq.push([...c.tags]); },
  });
  e.register("request:received", {
    id: "b", priority: 10,
    handler: (c) => { c.tag("b"); seq.push([...c.tags]); },
  });
  const ctx = createContext({ requestId: "r1" });
  await e.dispatch("request:received", ctx);
  // b runs first (priority 10), a sees b's tag
  assert.deepEqual(seq[0], ["b"]);
  assert.deepEqual(seq[1], ["b", "a"]);
});

test("engine: error isolation — throwing hook does not abort phase", async () => {
  const e = createEngine();
  e.register("request:received", {
    id: "boom", priority: 10,
    handler: () => { throw new Error("kaboom"); },
  });
  e.register("request:received", {
    id: "ok", priority: 20,
    handler: (c) => c.tag("survived"),
  });
  const ctx = createContext({ requestId: "r2" });
  await e.dispatch("request:received", ctx);
  assert.ok(ctx.tags.has("survived"));
  assert.equal(ctx.hookErrors.length, 1);
  assert.equal(ctx.hookErrors[0].id, "boom");
});

test("engine: per-hook timeout charges and continues", async () => {
  const e = createEngine();
  e.register("request:received", {
    id: "slow", timeout_ms: 10,
    handler: () => new Promise((r) => setTimeout(r, 100)),
  });
  e.register("request:received", {
    id: "after",
    handler: (c) => c.tag("after"),
  });
  const ctx = createContext({ requestId: "r3" });
  await e.dispatch("request:received", ctx);
  assert.ok(ctx.tags.has("after"));
  assert.equal(ctx.hookErrors[0].id, "slow");
});

test("engine: duplicate id within phase throws", () => {
  const e = createEngine();
  e.register("request:received", { id: "x", handler: () => {} });
  assert.throws(() => e.register("request:received", { id: "x", handler: () => {} }));
});

test("engine: unknown phase throws at registration", () => {
  const e = createEngine();
  assert.throws(() => e.register("nope:phase", { id: "z", handler: () => {} }));
});

// ---- registry ----

test("registry: resolves all built-in IDs", async () => {
  const ids = listBuiltinIds();
  assert.ok(ids.length >= 5);
  for (const id of ids) {
    const fn = await resolveHandler(`built-in:${id}`);
    assert.equal(typeof fn, "function");
  }
});

test("registry: unknown built-in throws", async () => {
  await assert.rejects(() => resolveHandler("built-in:nonexistent"));
});

// ---- handlers ----

test("tag-bash-read-elisions: tags Bash/Read elisions, ignores others", async () => {
  const ctx = createContext({ requestId: "r" });
  ctx.elidedIds = ["call_1", "call_2", "call_3"];
  ctx.outboundMessages = [
    { role: "assistant", tool_calls: [
      { id: "call_1", function: { name: "Bash" } },
      { id: "call_2", function: { name: "Glob" } },
      { id: "call_3", function: { name: "Read" } },
    ]},
  ];
  await tagBashRead(ctx);
  assert.ok(ctx.tags.has("elided:bash:call_1"));
  assert.ok(!ctx.tags.has("elided:glob:call_2"));
  assert.ok(ctx.tags.has("elided:read:call_3"));
  assert.ok(ctx.tags.has("bash-read-elided"));
});

test("context-pressure-reminder: injects when ratio > threshold", async () => {
  const ctx = createContext({ requestId: "r" });
  ctx.promptTokenFraction = 0.85;
  ctx.promptTokens = 100;
  ctx.nCtx = 200;
  ctx.messages = [{ role: "system", content: "sys" }, { role: "user", content: "hi" }];
  ctx.outboundMessages = ctx.messages;
  await ctxPressure(ctx, { threshold: 0.75 });
  assert.ok(ctx.tags.has("context-reminder-injected"));
  // Reminder placed before the final user message.
  const idx = ctx.messages.findIndex((m) => m._hook_injected);
  assert.ok(idx >= 0);
  assert.match(ctx.messages[idx].content, /Context is at 85%/);
});

test("context-pressure-reminder: no-op when below threshold", async () => {
  const ctx = createContext({ requestId: "r" });
  ctx.promptTokenFraction = 0.5;
  ctx.messages = [{ role: "user", content: "hi" }];
  await ctxPressure(ctx, { threshold: 0.75 });
  assert.equal(ctx.tags.size, 0);
});

test("once-per-session: tags + injects first time, skips second", async () => {
  resetOnce();
  const ctx1 = createContext({ requestId: "r1" });
  ctx1.headers = { "x-session-id": "S1" };
  ctx1.messages = [{ role: "user", content: "hi" }];
  ctx1.outboundMessages = ctx1.messages;
  await oncePerSession(ctx1);
  assert.ok(ctx1.tags.has("session-init-done"));
  assert.ok(ctx1.messages.some((m) => m._hook_injected));

  const ctx2 = createContext({ requestId: "r2" });
  ctx2.headers = { "x-session-id": "S1" };
  ctx2.messages = [{ role: "user", content: "hi2" }];
  ctx2.outboundMessages = ctx2.messages;
  await oncePerSession(ctx2);
  // Same session: tagged but no new injection.
  assert.ok(ctx2.tags.has("session-init-done"));
  assert.ok(!ctx2.messages.some((m) => m._hook_injected));
});

test("session-hint-loader: prepends file content as system message", async () => {
  const dir = mkdtempSync(resolve(tmpdir(), "qwen-hooks-"));
  const path = resolve(dir, "hint.txt");
  writeFileSync(path, "summary of prior turn");
  const ctx = createContext({ requestId: "r" });
  ctx.sessionHintPath = path;
  ctx.messages = [{ role: "user", content: "next" }];
  ctx.outboundMessages = ctx.messages;
  await sessionHintLoader(ctx);
  assert.ok(ctx.tags.has("session-hint-loaded"));
  assert.match(ctx.messages[0].content, /summary of prior turn/);
});

test("session-hint-loader: missing file is a silent no-op", async () => {
  const ctx = createContext({ requestId: "r" });
  ctx.sessionHintPath = "/tmp/does-not-exist-qwen-hooks-zzzz";
  ctx.messages = [{ role: "user", content: "hi" }];
  await sessionHintLoader(ctx);
  assert.equal(ctx.tags.size, 0);
});

test("prose-summarize: off when summarizer_url unset", async () => {
  const ctx = createContext({ requestId: "r" });
  ctx.messages = [{ role: "tool", content: "x".repeat(4000) }];
  await proseSummarize(ctx, {});
  assert.equal(ctx.tags.size, 0);
});
