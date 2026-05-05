// Tier 1 elision unit tests.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

import { applyTier1, buildToolNameIndex } from "../src/tier1.js";

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
