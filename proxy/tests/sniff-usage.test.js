// Regression tests for sniffUsage. The original flat-regex implementation
// stopped at the first `}` and silently failed on llama-server payloads that
// nest `prompt_tokens_details` inside `usage`, so completion_tokens was logged
// as null. The brace-balancing version handles nested objects.
import { test } from "node:test";
import assert from "node:assert/strict";
import { sniffUsage } from "../src/server.js";

test("sniffUsage: flat usage object", () => {
  const r = sniffUsage('{"foo":1,"usage":{"prompt_tokens":10,"completion_tokens":5}}');
  assert.deepEqual(r, { prompt_tokens: 10, completion_tokens: 5 });
});

test("sniffUsage: nested prompt_tokens_details (real llama-server shape)", () => {
  const real = `{"choices":[{"finish_reason":"stop","index":0,"message":{"role":"assistant","content":"ok"}}],"usage":{"completion_tokens":4,"prompt_tokens":17,"total_tokens":21,"prompt_tokens_details":{"cached_tokens":0}}}`;
  const r = sniffUsage(real);
  assert.equal(r.completion_tokens, 4);
  assert.equal(r.prompt_tokens, 17);
  assert.equal(r.total_tokens, 21);
  assert.deepEqual(r.prompt_tokens_details, { cached_tokens: 0 });
});

test("sniffUsage: streaming final-chunk shape with timings sibling", () => {
  const stream = `data: {"choices":[],"usage":{"completion_tokens":14,"prompt_tokens":263,"total_tokens":277,"prompt_tokens_details":{"cached_tokens":0}},"timings":{"cache_n":0,"prompt_n":263}}\n\ndata: [DONE]\n\n`;
  const r = sniffUsage(stream);
  assert.equal(r.completion_tokens, 14);
  assert.equal(r.prompt_tokens, 263);
});

test("sniffUsage: returns null when no usage present", () => {
  assert.equal(sniffUsage('{"choices":[]}'), null);
  assert.equal(sniffUsage(""), null);
});

test("sniffUsage: braces inside string content do not confuse depth counter", () => {
  const tricky = `{"choices":[{"message":{"content":"here is a brace } and another { in text"}}],"usage":{"prompt_tokens":1,"completion_tokens":2}}`;
  const r = sniffUsage(tricky);
  assert.equal(r.prompt_tokens, 1);
  assert.equal(r.completion_tokens, 2);
});

test("sniffUsage: escaped quotes in strings handled", () => {
  const tricky = `{"foo":"he said \\"hi\\" } no wait","usage":{"prompt_tokens":7,"completion_tokens":3}}`;
  const r = sniffUsage(tricky);
  assert.equal(r.prompt_tokens, 7);
  assert.equal(r.completion_tokens, 3);
});

test("sniffUsage: malformed usage returns null", () => {
  assert.equal(sniffUsage('"usage":{"prompt_tokens":1'), null);
});
