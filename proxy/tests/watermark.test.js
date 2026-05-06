// node --test tests for watermark.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  shouldCompact,
  shouldElideToolResult,
  defaultWatermarkConfig,
} from '../src/watermark.js';

const sys = { role: 'system', content: 'sys' };
const user = (i) => ({ role: 'user', content: `u${i}` });
const asst = (i) => ({ role: 'assistant', content: `a${i}` });

function makeConvo(n) {
  const out = [sys];
  for (let i = 0; i < n; i++) {
    out.push(i % 2 === 0 ? user(i) : asst(i));
  }
  return out;
}

test('defaults are documented', () => {
  assert.equal(defaultWatermarkConfig.watermarkRatio, 0.70);
  assert.equal(defaultWatermarkConfig.maxMessages, 40);
  assert.equal(defaultWatermarkConfig.maxAge, 20);
  assert.equal(defaultWatermarkConfig.toolResultMinTokens, 2000);
});

test('signal 1: token watermark fires at/above ratio', () => {
  const r = shouldCompact([user(0)], {
    nCtx: 1000,
    currentTokens: 700,
  });
  assert.equal(r.compact, true);
  assert.equal(r.reason, 'token_watermark');
  assert.equal(r.signals.tokenWatermark.hit, true);
});

test('signal 1: token watermark does not fire below ratio', () => {
  const r = shouldCompact([user(0)], {
    nCtx: 1000,
    currentTokens: 699,
  });
  assert.equal(r.compact, false);
  assert.equal(r.reason, 'under_watermark');
});

test('signal 1: respects custom watermarkRatio', () => {
  const r = shouldCompact([user(0)], {
    nCtx: 1000,
    currentTokens: 500,
    watermarkRatio: 0.5,
  });
  assert.equal(r.compact, true);
  assert.equal(r.reason, 'token_watermark');
});

test('signal 2: message_age fires when both count and age are exceeded', () => {
  // 41 messages: 1 system + 40 non-system. Oldest non-system at idx 1,
  // ageFromTail = 41 - 1 - 1 = 39 > 20. count 41 >= 40.
  const r = shouldCompact(makeConvo(40), {
    nCtx: 100000,
    currentTokens: 1000, // well under watermark
  });
  assert.equal(r.compact, true);
  assert.equal(r.reason, 'message_age');
  assert.equal(r.signals.messageAge.hit, true);
});

test('signal 2: does not fire when below maxMessages', () => {
  const r = shouldCompact(makeConvo(30), {
    nCtx: 100000,
    currentTokens: 1000,
  });
  assert.equal(r.compact, false);
});

test('signal 2: does not fire when count high but age low (system-heavy padding)', () => {
  // 40 messages all system except last 2 — oldest non-system close to tail.
  const msgs = [];
  for (let i = 0; i < 38; i++) msgs.push({ role: 'system', content: 'x' });
  msgs.push(user(0));
  msgs.push(asst(0));
  const r = shouldCompact(msgs, {
    nCtx: 100000,
    currentTokens: 1000,
  });
  // ageFromTail = 1, not > 20.
  assert.equal(r.compact, false);
});

test('signal 2: respects custom maxMessages and maxAge', () => {
  const r = shouldCompact(makeConvo(10), {
    nCtx: 100000,
    currentTokens: 1000,
    maxMessages: 5,
    maxAge: 3,
  });
  assert.equal(r.compact, true);
  assert.equal(r.reason, 'message_age');
});

test('edge: empty messages', () => {
  const r = shouldCompact([], { nCtx: 1000, currentTokens: 0 });
  assert.equal(r.compact, false);
  assert.equal(r.signals.messageAge.oldestNonSystemIdx, -1);
});

test('edge: system-only', () => {
  const r = shouldCompact([sys, sys, sys], {
    nCtx: 1000,
    currentTokens: 100,
  });
  assert.equal(r.compact, false);
  assert.equal(r.signals.messageAge.oldestNonSystemIdx, -1);
});

test('edge: nCtx zero does not divide-by-zero', () => {
  const r = shouldCompact([user(0)], { nCtx: 0, currentTokens: 999 });
  assert.equal(r.compact, false);
  assert.equal(r.signals.tokenWatermark.hit, false);
});

test('token watermark wins over message_age when both true', () => {
  const r = shouldCompact(makeConvo(40), {
    nCtx: 1000,
    currentTokens: 900,
  });
  assert.equal(r.compact, true);
  assert.equal(r.reason, 'token_watermark');
});

test('shouldElideToolResult: sync tokenizer above threshold', () => {
  const tok = (s) => s.length;
  assert.equal(shouldElideToolResult('x'.repeat(2500), 2000, tok), true);
});

test('shouldElideToolResult: sync tokenizer below threshold', () => {
  const tok = (s) => s.length;
  assert.equal(shouldElideToolResult('x'.repeat(100), 2000, tok), false);
});

test('shouldElideToolResult: default min from config', () => {
  const tok = (s) => s.length;
  assert.equal(
    shouldElideToolResult('x'.repeat(2000), undefined, tok),
    true,
  );
  assert.equal(
    shouldElideToolResult('x'.repeat(1999), undefined, tok),
    false,
  );
});

test('shouldElideToolResult: empty/non-string returns false', () => {
  const tok = () => 9999;
  assert.equal(shouldElideToolResult('', 100, tok), false);
  assert.equal(shouldElideToolResult(null, 100, tok), false);
  assert.equal(shouldElideToolResult(undefined, 100, tok), false);
});

test('shouldElideToolResult: missing tokenizer throws', () => {
  assert.throws(() => shouldElideToolResult('hello', 100));
});

test('shouldElideToolResult: async tokenizer returns a Promise', async () => {
  const tok = async (s) => s.length;
  const p = shouldElideToolResult('x'.repeat(2500), 2000, tok);
  assert.ok(p && typeof p.then === 'function');
  assert.equal(await p, true);
});

// ---------- realistic tokenizer + threshold sanity -------------------------

// Fake-but-realistic tokenizer. qwen-class BPE on English+code averages
// roughly 3.5 chars/token (tighter than the GPT-3 chars/4 rule of thumb).
// We use it here to verify thresholds fire at message volumes operators
// would actually see in the wild — without requiring a running /tokenize
// endpoint.
const qwenIshTok = (s) => Math.ceil((s ? String(s).length : 0) / 3.5);

test('watermark: realistic 50K-token request fires at 70% of 64K ctx', () => {
  // 50000 tokens out of 65536 ≈ 76.3% > 70% threshold.
  const r = shouldCompact([user(0)], {
    nCtx: 65536,
    currentTokens: 50000,
  });
  assert.equal(r.compact, true);
  assert.equal(r.reason, 'token_watermark');
});

test('watermark: realistic 30K-token request stays under 70% of 64K ctx', () => {
  const r = shouldCompact([user(0)], {
    nCtx: 65536,
    currentTokens: 30000,
  });
  assert.equal(r.compact, false);
});

test('shouldElideToolResult: qwen-ish tokenizer fires near 7000 chars', () => {
  // 2000 tokens * 3.5 chars/token = 7000 chars threshold under qwenIshTok.
  // ceil(6999/3.5) = 2000, so 6999 is exactly at threshold.
  // ceil(6996/3.5) = 1999, just under.
  assert.equal(shouldElideToolResult('a'.repeat(6996), 2000, qwenIshTok), false);
  assert.equal(shouldElideToolResult('a'.repeat(7000), 2000, qwenIshTok), true);
  // A typical pytest-verbose log of ~10K chars → fires.
  assert.equal(shouldElideToolResult('x'.repeat(10000), 2000, qwenIshTok), true);
});

// ---------- precedence and orthogonality -----------------------------------

test('precedence: token_watermark wins when both signals fire', () => {
  // 41 messages (1 sys + 40 non-system) AND tokens at 75% of nCtx.
  const r = shouldCompact(makeConvo(40), {
    nCtx: 1000,
    currentTokens: 750,
  });
  assert.equal(r.compact, true);
  assert.equal(r.reason, 'token_watermark');
  // Both signals flagged in the diagnostic payload.
  assert.equal(r.signals.tokenWatermark.hit, true);
  assert.equal(r.signals.messageAge.hit, true);
});

test('orthogonality: tool-result elision is independent of shouldCompact', () => {
  // Build a "small, healthy" session: under any watermark.
  const msgs = [sys, user(0), asst(0)];
  const compactDecision = shouldCompact(msgs, { nCtx: 100000, currentTokens: 100 });
  assert.equal(compactDecision.compact, false);
  assert.equal(compactDecision.reason, 'under_watermark');

  // But a single bloated tool result inside that same session still elides.
  const bigResult = 'log line\n'.repeat(2000); // ~18000 chars → ~5143 tokens
  assert.equal(shouldElideToolResult(bigResult, 2000, qwenIshTok), true);

  // And: shouldCompact's decision is unaffected by what's inside the
  // tool-result blob — it only sees currentTokens. Elision is a per-result
  // decision that the proxy applies regardless of (1)/(2).
});

// ---------- property-style robustness --------------------------------------

test('property: shouldCompact never throws and always returns a valid shape', () => {
  // Deterministic PRNG so failures are reproducible.
  function mulberry32(a) {
    return function () {
      a |= 0;
      a = (a + 0x6d2b79f5) | 0;
      let t = a;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  const rand = mulberry32(0xBADF00D);
  const roles = ['system', 'user', 'assistant', 'tool', 'unknown', undefined];
  const validReasons = new Set(['token_watermark', 'message_age', 'under_watermark']);

  const generators = [
    () => null,
    () => undefined,
    () => [],
    () => 'not-an-array',
    () => 42,
    () => ({ not: 'array' }),
    () => Array.from({ length: Math.floor(rand() * 80) }, () => ({
      role: roles[Math.floor(rand() * roles.length)],
      content: rand() < 0.3 ? null : 'x'.repeat(Math.floor(rand() * 50)),
    })),
    () => Array.from({ length: 100 }, (_, i) => ({ role: i === 0 ? 'system' : 'user', content: '.' })),
    () => [{ role: 'tool', tool_call_id: 'x', content: '' }],
  ];
  const ctxGenerators = [
    () => undefined,
    () => null,
    () => ({}),
    () => ({ nCtx: 0, currentTokens: 0 }),
    () => ({ nCtx: -1, currentTokens: -1 }),
    () => ({ nCtx: Math.floor(rand() * 1e6), currentTokens: Math.floor(rand() * 2e6) }),
    () => ({ nCtx: 1000, currentTokens: 'NaN' }),
    () => ({ nCtx: 1024, currentTokens: 700, watermarkRatio: rand() }),
    () => ({ nCtx: 1024, currentTokens: 700, maxMessages: Math.floor(rand() * 100), maxAge: Math.floor(rand() * 100) }),
  ];

  for (let i = 0; i < 500; i++) {
    const msgs = generators[Math.floor(rand() * generators.length)]();
    const ctx = ctxGenerators[Math.floor(rand() * ctxGenerators.length)]();
    let r;
    assert.doesNotThrow(() => {
      r = shouldCompact(msgs, ctx);
    }, `shouldCompact threw for case ${i}`);
    assert.equal(typeof r, 'object');
    assert.notEqual(r, null);
    assert.equal(typeof r.compact, 'boolean');
    assert.equal(typeof r.reason, 'string');
    assert.ok(validReasons.has(r.reason), `unexpected reason: ${r.reason}`);
    // compact==true iff reason names a hit signal
    if (r.compact) {
      assert.ok(r.reason === 'token_watermark' || r.reason === 'message_age');
    } else {
      assert.equal(r.reason, 'under_watermark');
    }
  }
});
