// Phase 4 (structured notes — Tier 2/3) and Phase 5 (sumy fallback — Tier 4)
// tests. Covers:
//   1. extractNotesFromToolResult on a synthetic body with 3+ entities.
//   2. extractNotesFromToolResult on plain prose returns ~empty.
//   3. formatNotes emits a `<tool_result_notes>` envelope.
//   4. rewriteRequest with notes.enabled trips on oversized body and replaces
//      the content in enforce-equivalent path.
//   5. rewriteRequest with notes.enabled but unyielding body falls through to
//      Tier 1 verbatim stub.
//   6. rewriteRequest with sumy.enabled extractive fallback when notes empty.
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

import {
  extractNotesFromToolResult,
  formatNotes,
  sumyExtractive,
} from "../src/notes.js";
import { rewriteRequest } from "../src/rewrite.js";
import { LRU } from "../src/lru.js";

function makeTokenizer() {
  const cache = new LRU(1024);
  return {
    cache,
    async countTokens(text) {
      if (!text) return 0;
      const hit = cache.get(text);
      if (typeof hit === "number") return hit;
      const n = Math.max(1, Math.ceil(String(text).length / 4));
      cache.set(text, n);
      return n;
    },
  };
}

function baseWatermarks(extra = {}) {
  return {
    prompt_fraction: 0.5,
    tool_result_min_tokens: 2000,
    max_messages: 40,
    max_age_turns: 20,
    verbatim_keep_turns: 0,
    verbatim_keep_tokens: 0,
    ...extra,
  };
}

test("extractNotesFromToolResult: pulls entities/kv/decisions from synthetic body", () => {
  const body = `
AGREED: ship the thing tomorrow
status=ok port: 11500
The class HttpAuthHandler lives at src/auth/handler.py
{"user_id": 42, "role": "admin"}
D-12 follow-up to D-11
  `.trim();
  const recs = extractNotesFromToolResult(body);
  assert.ok(recs.length >= 3, `expected >=3 records, got ${recs.length}`);
  const kinds = new Set(recs.map((r) => r.kind));
  assert.ok(kinds.has("decision"), "should find a decision marker");
  assert.ok(kinds.has("kv"), "should find a key=value pair");
  assert.ok(
    kinds.has("entity") || kinds.has("json"),
    "should find an entity or json block",
  );
});

test("extractNotesFromToolResult: plain prose yields near-empty", () => {
  const body =
    "the quick brown fox jumps over the lazy dog. it was a quiet morning by the lake and nothing much happened.";
  const recs = extractNotesFromToolResult(body);
  // No CamelCase, no key=value, no decision markers, no JSON blocks.
  assert.equal(recs.length, 0);
});

test("formatNotes: emits <tool_result_notes> envelope", () => {
  const out = formatNotes(
    [
      { kind: "decision", value: "AGREED ship", span: [0, 11] },
      { kind: "entity", value: "FooBarBaz", span: [12, 21] },
    ],
    { tool: "Read" },
  );
  assert.match(out, /^<tool_result_notes tool="Read">/);
  assert.match(out, /<note kind="decision">AGREED ship<\/note>/);
  assert.match(out, /<note kind="entity">FooBarBaz<\/note>/);
  assert.match(out, /<\/tool_result_notes>$/);
});

test("rewriteRequest: notes-enabled replaces oversized body with notes envelope", async () => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "notes-test-"));
  // Build a body that is >2000 tokens AND riddled with extractable entities.
  const filler = "AGREED: keep going. status=ok port: 11500 ClassFooHandler at src/foo/bar.py\n";
  const big = filler.repeat(200); // ~14k chars -> ~3500 tokens
  const body = {
    model: "stub",
    messages: [
      { role: "user", content: "hi" },
      {
        role: "assistant",
        content: null,
        tool_calls: [
          { id: "call_a", type: "function", function: { name: "Read", arguments: "{}" } },
        ],
      },
      { role: "tool", tool_call_id: "call_a", name: "Read", content: big },
      { role: "user", content: "now what" },
    ],
  };
  const r = await rewriteRequest({
    body,
    tokenizer: makeTokenizer(),
    config: {
      watermarks: baseWatermarks(),
      summarizer: { url: "", mode: "off" },
      notes: { enabled: true, min_tokens_to_extract: 200 },
      sumy: { enabled: false },
    },
    cacheDir,
    nCtx: 4000,
  });
  assert.ok(r.stats.notes_count >= 1, `expected notes_count>=1, got ${r.stats.notes_count}`);
  assert.equal(r.stats.elided_tool_result_ids.length, 0, "Tier 1 should NOT re-stub");
  assert.match(r.rewrittenBody.messages[2].content, /^<tool_result_notes\b/);
});

test("rewriteRequest: notes-enabled with unyielding body falls through to Tier 1 stub", async () => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "notes-test-"));
  // Long body of ONLY lowercase prose — no entities, no kv, no decisions.
  const big = "the quiet morning passed without incident on the lake. ".repeat(300);
  const body = {
    model: "stub",
    messages: [
      { role: "user", content: "hi" },
      {
        role: "assistant",
        content: null,
        tool_calls: [
          { id: "call_a", type: "function", function: { name: "Read", arguments: "{}" } },
        ],
      },
      { role: "tool", tool_call_id: "call_a", name: "Read", content: big },
      { role: "user", content: "now what" },
    ],
  };
  const r = await rewriteRequest({
    body,
    tokenizer: makeTokenizer(),
    config: {
      watermarks: baseWatermarks(),
      summarizer: { url: "", mode: "off" },
      notes: { enabled: true, min_tokens_to_extract: 200 },
      sumy: { enabled: false },
    },
    cacheDir,
    nCtx: 4000,
  });
  assert.equal(r.stats.notes_count, 0);
  assert.equal(r.stats.sumy_used, 0);
  // No notes -> no replacement -> Tier 1 still stubs the giant body.
  assert.equal(r.stats.elided_tool_result_ids.length, 1);
  assert.match(r.rewrittenBody.messages[2].content, /^<tool_result\b/);
});

test("rewriteRequest: sumy-enabled extractive fallback fires when notes is empty", async () => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "notes-test-"));
  // Prose-only body so notes finds nothing — sumy should kick in.
  const big = "the quiet morning passed without incident on the lake. ".repeat(300);
  const body = {
    model: "stub",
    messages: [
      { role: "user", content: "hi" },
      {
        role: "assistant",
        content: null,
        tool_calls: [
          { id: "call_a", type: "function", function: { name: "Read", arguments: "{}" } },
        ],
      },
      { role: "tool", tool_call_id: "call_a", name: "Read", content: big },
      { role: "user", content: "now what" },
    ],
  };
  const r = await rewriteRequest({
    body,
    tokenizer: makeTokenizer(),
    config: {
      watermarks: baseWatermarks(),
      summarizer: { url: "", mode: "off" },
      notes: { enabled: true, min_tokens_to_extract: 200 },
      sumy: { enabled: true, target_sentences: 3 },
    },
    cacheDir,
    nCtx: 4000,
  });
  assert.equal(r.stats.notes_count, 0);
  assert.equal(r.stats.sumy_used, 1);
  assert.equal(r.stats.elided_tool_result_ids.length, 0);
  assert.match(
    r.rewrittenBody.messages[2].content,
    /^<tool_result_summary tool="Read" source="sumy">/,
  );
  // Sanity: standalone sumyExtractive returns non-empty, fewer chars than input.
  const out = sumyExtractive(big, { targetSentences: 3 });
  assert.ok(out.length > 0 && out.length < big.length);
});
