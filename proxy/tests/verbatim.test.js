// Verbatim window unit tests (Tier 0).
import { test } from "node:test";
import assert from "node:assert/strict";
import { pickVerbatim } from "../src/verbatim.js";

test("pickVerbatim: empty messages", () => {
  const r = pickVerbatim([], {});
  assert.equal(r.verbatimIndices.size, 0);
  assert.deepEqual(r.evictableIndices, []);
});

test("pickVerbatim: only system → all kept, none evictable", () => {
  const msgs = [
    { role: "system", content: "you are a helper" },
    { role: "system", content: "be concise" },
  ];
  const r = pickVerbatim(msgs, { keepTurns: 8, keepTokens: 8000 });
  assert.equal(r.verbatimIndices.size, 2);
  assert.deepEqual(r.evictableIndices, []);
});

test("pickVerbatim: short session entirely fits in window", () => {
  const msgs = [
    { role: "system", content: "sys" },
    { role: "user", content: "hello" },
    { role: "assistant", content: "hi" },
    { role: "user", content: "again" },
  ];
  const r = pickVerbatim(msgs, { keepTurns: 8, keepTokens: 8000 });
  assert.equal(r.evictableIndices.length, 0);
  assert.equal(r.verbatimIndices.size, msgs.length);
});

test("pickVerbatim: long session evicts middle, keeps system + last K turns + last user", () => {
  const msgs = [{ role: "system", content: "sys" }];
  for (let i = 0; i < 30; i++) {
    msgs.push({
      role: i % 2 === 0 ? "user" : "assistant",
      content: `turn ${i}`,
    });
  }
  // tokenCounts ~ 3/each, so token bound trivial. Turn bound dominates.
  const counts = msgs.map(() => 3);
  const r = pickVerbatim(msgs, {
    keepTurns: 8,
    keepTokens: 0,
    tokenCounts: counts,
  });
  // System + last 8 turns kept = 9 verbatim, last user (already in last 8) too.
  assert.equal(r.verbatimIndices.has(0), true, "system kept");
  assert.equal(r.verbatimIndices.size, 9);
  // Earliest evictable is index 1 (first non-system).
  assert.equal(r.evictableIndices[0], 1);
});

test("pickVerbatim: token bound exceeds turn bound (keeps more)", () => {
  const msgs = [{ role: "system", content: "sys" }];
  for (let i = 0; i < 20; i++) {
    msgs.push({ role: "user", content: `m${i}` });
  }
  // Each "turn" 100 tokens. keepTokens=1000 means we need >=10 turns of 100 ea
  // before the token bound is satisfied (10 * 100 = 1000), and keepTurns=4
  // means we keep 4 by turns. Since whichever-is-larger applies, we keep 10.
  const counts = msgs.map(() => 100);
  const r = pickVerbatim(msgs, {
    keepTurns: 4,
    keepTokens: 1000,
    tokenCounts: counts,
  });
  // 10 turns + system = 11 verbatim.
  assert.equal(r.verbatimIndices.size, 11);
});

test("pickVerbatim: keepTurns=0 keepTokens=0 still keeps system + last user (no crash)", () => {
  const msgs = [
    { role: "system", content: "sys" },
    { role: "assistant", content: "old" },
    { role: "user", content: "current" },
  ];
  const r = pickVerbatim(msgs, { keepTurns: 0, keepTokens: 0 });
  assert.equal(r.verbatimIndices.has(0), true, "system");
  assert.equal(r.verbatimIndices.has(2), true, "last user");
  // Assistant in the middle is evictable.
  assert.deepEqual(r.evictableIndices, [1]);
});

test("pickVerbatim: every message is system → no evictable, no crash", () => {
  const msgs = [
    { role: "system", content: "a" },
    { role: "system", content: "b" },
    { role: "system", content: "c" },
  ];
  const r = pickVerbatim(msgs, { keepTurns: 0, keepTokens: 0 });
  assert.equal(r.verbatimIndices.size, 3);
  assert.deepEqual(r.evictableIndices, []);
});

test("pickVerbatim: single user message → kept, no crash", () => {
  const r = pickVerbatim([{ role: "user", content: "hi" }], {
    keepTurns: 0,
    keepTokens: 0,
  });
  assert.equal(r.verbatimIndices.has(0), true);
  assert.deepEqual(r.evictableIndices, []);
});

test("pickVerbatim: single assistant message (no user) → evictable, no crash", () => {
  const r = pickVerbatim([{ role: "assistant", content: "hi" }], {
    keepTurns: 0,
    keepTokens: 0,
  });
  // No user to preserve, no system, all bounds = 0 → message is evictable.
  assert.deepEqual(r.evictableIndices, [0]);
});

test("pickVerbatim: null/undefined messages array does not crash", () => {
  assert.doesNotThrow(() => pickVerbatim(null, {}));
  assert.doesNotThrow(() => pickVerbatim(undefined, {}));
  const r = pickVerbatim(null, {});
  assert.deepEqual(r.evictableIndices, []);
});

test("pickVerbatim: messages with null entries do not crash", () => {
  const msgs = [
    { role: "system", content: "sys" },
    null,
    { role: "user", content: "hi" },
  ];
  assert.doesNotThrow(() => pickVerbatim(msgs, {}));
});

test("pickVerbatim: last user always preserved even with tiny K", () => {
  const msgs = [
    { role: "system", content: "sys" },
    { role: "user", content: "old" },
    { role: "assistant", content: "old reply" },
    { role: "user", content: "current" },
  ];
  const r = pickVerbatim(msgs, { keepTurns: 0, keepTokens: 0 });
  assert.equal(r.verbatimIndices.has(3), true);
  assert.equal(r.verbatimIndices.has(0), true);
});
