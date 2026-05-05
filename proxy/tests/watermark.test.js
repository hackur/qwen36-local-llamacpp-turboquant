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
