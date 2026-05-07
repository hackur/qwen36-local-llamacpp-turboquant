// Phase 3 — session keying + stable-prefix tests.
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  keyForRequest,
  extractStablePrefix,
  createSessionStore,
} from "../src/session.js";

function fakeReq(headers = {}) {
  return { headers };
}

test("keyForRequest is stable across two identical request bodies", () => {
  const body = {
    user: "alice",
    messages: [{ role: "system", content: "you are helpful" }],
  };
  const req = fakeReq();
  const a = keyForRequest(req, body);
  const b = keyForRequest(req, JSON.parse(JSON.stringify(body)));
  assert.equal(a, b);
  assert.match(a, /^[0-9a-f]{32}$/);
});

test("keyForRequest differs across different user fields", () => {
  const req = fakeReq();
  const a = keyForRequest(req, { user: "alice", messages: [] });
  const b = keyForRequest(req, { user: "bob", messages: [] });
  assert.notEqual(a, b);
});

test("keyForRequest falls back to message-hash when no user/header", () => {
  const req = fakeReq();
  const a = keyForRequest(req, {
    messages: [{ role: "system", content: "hello" }],
  });
  const b = keyForRequest(req, {
    messages: [{ role: "system", content: "different" }],
  });
  const c = keyForRequest(req, {
    messages: [{ role: "system", content: "hello" }],
  });
  assert.notEqual(a, b);
  assert.equal(a, c);
});

test("extractStablePrefix returns expected prefix length on known input", () => {
  const messages = [
    { role: "system", content: "sys-1" },
    { role: "system", content: "sys-2" },
    { role: "user", content: "first user turn" },
    { role: "assistant", content: "reply" },
    { role: "user", content: "second user turn" },
  ];
  const { prefix, prefixHash, prefixTokens } = extractStablePrefix(messages);
  assert.equal(prefix.length, 3);
  assert.equal(prefix[0].role, "system");
  assert.equal(prefix[2].role, "user");
  assert.match(prefixHash, /^[0-9a-f]{64}$/);
  assert.ok(prefixTokens > 0);
});

test("in-memory session map evicts after TTL with injected clock", () => {
  let now = 1_000_000;
  const store = createSessionStore({
    ttlSeconds: 60,
    clock: () => now,
  });
  store.touch("session-a");
  assert.equal(store.size(), 1);
  // advance past TTL
  now += 61_000;
  store.touch("session-b");
  // session-a should have been evicted by the touch() pass
  assert.equal(store.size(), 1);
  assert.ok(store.map.has("session-b"));
  assert.ok(!store.map.has("session-a"));
});
