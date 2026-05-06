// Tier 1 elision unit tests.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

import { applyTier1, buildToolNameIndex, summarizeElidedIds } from "../src/tier1.js";

function makeTokenCount() {
  // Cheap deterministic tokenizer: 1 token per 4 chars.
  return (text) => (text ? Math.max(1, Math.ceil(String(text).length / 4)) : 0);
}

test("tier1: large tool result becomes a stub and is persisted", () => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "tier1-test-"));
  // 12000 chars → ~3000 tokens with our stub tokenizer (>2000 default).
  const big = "x".repeat(12000);
  const messages = [
    { role: "system", content: "sys" },
    {
      role: "assistant",
      content: null,
      tool_calls: [
        {
          id: "call_abc",
          type: "function",
          function: { name: "Read", arguments: '{"path":"foo.py"}' },
        },
      ],
    },
    {
      role: "tool",
      tool_call_id: "call_abc",
      name: "Read",
      content: big,
    },
    { role: "user", content: "what next" },
  ];
  const idx = buildToolNameIndex(messages);
  assert.equal(idx.get("call_abc"), "Read");
  const r = applyTier1({
    messages,
    evictableIndices: [2],
    opts: {
      minTokens: 2000,
      cacheDir,
      tokenCount: makeTokenCount(),
      toolNameFromCallId: idx,
    },
  });
  assert.equal(r.elidedIds.length, 1);
  assert.equal(r.elidedIds[0], "call_abc");
  const stub = r.rewrittenMessages[2].content;
  assert.match(stub, /^<tool_result id="call_abc"/);
  assert.match(stub, /tool="Read"/);
  assert.match(stub, /bytes=12000/);
  assert.ok(r.tokensSavedEstimate > 0);
  // Persisted file with the verbatim original content.
  const path = resolve(cacheDir, "tool-results", "call_abc.json");
  assert.ok(existsSync(path));
  const stored = JSON.parse(readFileSync(path, "utf8"));
  assert.equal(stored.content, big);
});

test("tier1: small tool result is left verbatim", () => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "tier1-test-"));
  const small = "tiny output";
  const messages = [
    { role: "tool", tool_call_id: "x", name: "Bash", content: small },
  ];
  const r = applyTier1({
    messages,
    evictableIndices: [0],
    opts: {
      minTokens: 2000,
      cacheDir,
      tokenCount: makeTokenCount(),
    },
  });
  assert.equal(r.elidedIds.length, 0);
  assert.equal(r.rewrittenMessages[0].content, small);
});

test("tier1: anthropic-style content blocks with tool_result get elided", () => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "tier1-test-"));
  const big = "y".repeat(12000);
  const messages = [
    {
      role: "user",
      content: [
        { type: "tool_result", tool_use_id: "tc_z", content: big },
        { type: "text", text: "side note" },
      ],
    },
  ];
  const r = applyTier1({
    messages,
    evictableIndices: [0],
    opts: {
      minTokens: 2000,
      cacheDir,
      tokenCount: makeTokenCount(),
    },
  });
  assert.equal(r.elidedIds.length, 1);
  const part = r.rewrittenMessages[0].content[0];
  assert.equal(part.type, "tool_result");
  assert.match(part.content, /<tool_result id="tc_z"/);
  // Other parts untouched.
  assert.equal(r.rewrittenMessages[0].content[1].text, "side note");
});

test("tier1: hash-stable id for content with no tool_call_id", () => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "tier1-test-"));
  const big = "z".repeat(12000);
  const m = [{ role: "tool", content: big, name: "X" }];
  const r1 = applyTier1({
    messages: m,
    evictableIndices: [0],
    opts: { minTokens: 2000, cacheDir, tokenCount: makeTokenCount() },
  });
  const r2 = applyTier1({
    messages: m,
    evictableIndices: [0],
    opts: { minTokens: 2000, cacheDir, tokenCount: makeTokenCount() },
  });
  assert.equal(r1.elidedIds[0], r2.elidedIds[0]);
  assert.match(r1.elidedIds[0], /^t-[0-9a-f]{12}$/);
});

test("tier1: identical content with no tool_call_id collides on disk (idempotent overwrite)", () => {
  // Two evictable tool messages with identical body and no tool_call_id should
  // hash to the same id. Persistence overwrites the same file with identical
  // content — that's the documented, intended behavior.
  const cacheDir = mkdtempSync(resolve(tmpdir(), "tier1-test-"));
  const big = "k".repeat(12000);
  const messages = [
    { role: "tool", name: "Read", content: big },
    { role: "tool", name: "Read", content: big },
  ];
  const writes = [];
  const r = applyTier1({
    messages,
    evictableIndices: [0, 1],
    opts: {
      minTokens: 2000,
      cacheDir,
      tokenCount: makeTokenCount(),
      persistFn: (id, payload) => writes.push({ id, content: payload.content }),
    },
  });
  // Both elide to the SAME id (collision is intentional for identical bodies).
  assert.equal(r.elidedIds.length, 2);
  assert.equal(r.elidedIds[0], r.elidedIds[1]);
  // Both writes target the same id, payloads identical → safe overwrite.
  assert.equal(writes.length, 2);
  assert.equal(writes[0].id, writes[1].id);
  assert.equal(writes[0].content, writes[1].content);
});

test("tier1: distinct tool_call_ids never collide even with identical bodies", () => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "tier1-test-"));
  const big = "m".repeat(12000);
  const messages = [
    { role: "tool", tool_call_id: "call_1", name: "Read", content: big },
    { role: "tool", tool_call_id: "call_2", name: "Read", content: big },
  ];
  const r = applyTier1({
    messages,
    evictableIndices: [0, 1],
    opts: { minTokens: 2000, cacheDir, tokenCount: makeTokenCount() },
  });
  assert.deepEqual(r.elidedIds, ["call_1", "call_2"]);
  // Two distinct files on disk.
  assert.ok(existsSync(resolve(cacheDir, "tool-results", "call_1.json")));
  assert.ok(existsSync(resolve(cacheDir, "tool-results", "call_2.json")));
});

test("tier1: nested anthropic tool_result content (array of text blocks)", () => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "tier1-test-"));
  const big = "n".repeat(12000);
  const messages = [
    {
      role: "user",
      content: [
        {
          type: "tool_result",
          tool_use_id: "tc_nested",
          content: [{ type: "text", text: big }],
        },
      ],
    },
  ];
  const r = applyTier1({
    messages,
    evictableIndices: [0],
    opts: { minTokens: 2000, cacheDir, tokenCount: makeTokenCount() },
  });
  assert.equal(r.elidedIds.length, 1);
  const stub = r.rewrittenMessages[0].content[0].content;
  assert.match(stub, /^<tool_result id="tc_nested"/);
  assert.match(stub, /bytes=12000/);
});

test("tier1: anthropic tool_result with flat-string content also works", () => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "tier1-test-"));
  const big = "f".repeat(12000);
  const messages = [
    {
      role: "user",
      content: [{ type: "tool_result", tool_use_id: "tc_flat", content: big }],
    },
  ];
  const r = applyTier1({
    messages,
    evictableIndices: [0],
    opts: { minTokens: 2000, cacheDir, tokenCount: makeTokenCount() },
  });
  assert.equal(r.elidedIds.length, 1);
  assert.match(r.rewrittenMessages[0].content[0].content, /^<tool_result id="tc_flat"/);
});

test("tier1: first_lines escapes adversarial chars (quotes, angle brackets, ampersand, newlines)", () => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "tier1-test-"));
  const adversarial =
    `line "1" with <html> & special\n` +
    `line "2" with </tool_result>\n` +
    `line 3\nline4\nline5\n`;
  const big = adversarial + "p".repeat(12000);
  const messages = [
    { role: "tool", tool_call_id: "adv", name: "Read", content: big },
  ];
  const r = applyTier1({
    messages,
    evictableIndices: [0],
    opts: { minTokens: 2000, cacheDir, tokenCount: makeTokenCount() },
  });
  const stub = r.rewrittenMessages[0].content;
  // No raw double-quotes, < or > inside the first_lines value.
  const fl = stub.match(/first_lines="([^"]*)"/);
  assert.ok(fl, "first_lines attribute present");
  const flVal = fl[1];
  assert.ok(!/[<>]/.test(flVal), "no raw angle brackets");
  assert.ok(!/\n/.test(flVal), "newlines escaped");
  // Encoded entities present.
  assert.match(flVal, /&quot;/);
  assert.match(flVal, /&lt;/);
  assert.match(flVal, /&gt;/);
  assert.match(flVal, /&amp;/);
  assert.match(flVal, /\\n/);
  // Stub itself is well-formed (single root element, balanced quotes).
  const quoteCount = (stub.match(/"/g) || []).length;
  assert.equal(quoteCount % 2, 0, "balanced quotes");
});

test("tier1: bytes attribute uses UTF-8 byte length, not char length", () => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "tier1-test-"));
  // Mix of multi-byte sequences: Chinese (3 bytes) + emoji (4 bytes via surrogate pair, 4 UTF-8 bytes)
  const unit = "你好🚀"; // 3 chars in JS counting surrogate pair as 2 → length=4; UTF-8 = 3+3+4 = 10 bytes
  const body = unit.repeat(3000); // length=12000 UTF-16 units, 30000 UTF-8 bytes
  const messages = [
    { role: "tool", tool_call_id: "mb", name: "R", content: body },
  ];
  const r = applyTier1({
    messages,
    evictableIndices: [0],
    opts: { minTokens: 2000, cacheDir, tokenCount: makeTokenCount() },
  });
  const stub = r.rewrittenMessages[0].content;
  const m = stub.match(/bytes=(\d+)/);
  assert.ok(m);
  const bytes = parseInt(m[1], 10);
  assert.equal(bytes, Buffer.byteLength(body, "utf8"));
  assert.notEqual(bytes, body.length, "byte count differs from char count");
  assert.equal(bytes, 30000);
});

test("tier1: summarizeElidedIds caps long lists with total_count", () => {
  const big = Array.from({ length: 200 }, (_, i) => `call_${"x".repeat(40)}_${i}`);
  const s = summarizeElidedIds(big, { maxIds: 64, maxBytes: 4096 });
  assert.equal(s.total_count, 200);
  assert.equal(s.truncated, true);
  assert.ok(s.ids.length <= 64);
  // JSON encoding stays within budget.
  assert.ok(Buffer.byteLength(JSON.stringify(s.ids), "utf8") <= 4096);
});

test("tier1: summarizeElidedIds passes short lists through unchanged", () => {
  const ids = ["a", "b", "c"];
  const s = summarizeElidedIds(ids);
  assert.deepEqual(s.ids, ids);
  assert.equal(s.total_count, 3);
  assert.equal(s.truncated, false);
});

test("tier1: summarizeElidedIds handles non-array input safely", () => {
  assert.deepEqual(summarizeElidedIds(undefined), { ids: [], total_count: 0, truncated: false });
  assert.deepEqual(summarizeElidedIds(null), { ids: [], total_count: 0, truncated: false });
});

test("tier1: rewrite is synchronous and produces JSON-serialisable output (streaming-safe)", () => {
  // The rewrite runs before forwarding; it must not depend on streaming I/O,
  // not retain references to mutable upstream buffers, and must round-trip
  // through JSON.stringify so server.js can hand the rewritten body to fetch().
  const cacheDir = mkdtempSync(resolve(tmpdir(), "tier1-test-"));
  const big = "s".repeat(12000);
  const messages = [
    { role: "system", content: "sys" },
    { role: "user", content: "do something" },
    { role: "tool", tool_call_id: "call_s", name: "Read", content: big },
    { role: "user", content: "done?" },
  ];
  const start = Date.now();
  const r = applyTier1({
    messages,
    evictableIndices: [2],
    opts: { minTokens: 2000, cacheDir, tokenCount: makeTokenCount() },
  });
  // Synchronous: returns a plain object, not a Promise.
  assert.equal(typeof r.then, "undefined");
  // Result is fully serialisable (no circular refs, no unserialisable values).
  const json = JSON.stringify(r.rewrittenMessages);
  assert.ok(json.length > 0);
  // Original messages are not mutated in place.
  assert.equal(messages[2].content, big);
  // And it ran fast (deterministic, no I/O on the hot path with persistFn injected).
  assert.ok(Date.now() - start < 1000);
});

test("tier1: verbatim messages are not touched (only evictable indices)", () => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "tier1-test-"));
  const big = "q".repeat(12000);
  const messages = [
    { role: "tool", tool_call_id: "keep", name: "Read", content: big },
    { role: "tool", tool_call_id: "drop", name: "Read", content: big },
  ];
  const r = applyTier1({
    messages,
    evictableIndices: [1], // index 0 is in verbatim window
    opts: { minTokens: 2000, cacheDir, tokenCount: makeTokenCount() },
  });
  assert.equal(r.rewrittenMessages[0].content, big, "verbatim untouched");
  assert.match(r.rewrittenMessages[1].content, /^<tool_result/);
});
