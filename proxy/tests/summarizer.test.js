// Phase 2 summarizer tests.
//
// Covers:
//   1. summarize() success: posts to a stub /v1/chat/completions and returns text.
//   2. summarize() bypass when url is empty / server offline.
//   3. summarize() bypass on invalid JSON response.
//   4. summarize() bypass on timeout (AbortController).
//   5. rewriteRequest no-op when watermark not tripped.
//   6. rewriteRequest enforce path replaces oversized tool-result with summary
//      so Tier 1 does NOT stub it.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

import { summarize } from "../src/summarizer.js";
import { rewriteRequest } from "../src/rewrite.js";
import { LRU } from "../src/lru.js";

// Fake tokenizer matching the shape rewrite.js consumes:
//   - .cache.get(text) -> number | undefined
//   - .countTokens(text) -> Promise<number>
// Deterministic: 1 token per 4 chars.
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

function startStubSummarizer(handler) {
  return new Promise((res) => {
    const server = createServer((req, response) => {
      if (req.url === "/v1/chat/completions" && req.method === "POST") {
        let body = "";
        req.on("data", (c) => (body += c));
        req.on("end", () => handler(JSON.parse(body), response));
        return;
      }
      response.writeHead(404);
      response.end();
    });
    server.listen(0, "127.0.0.1", () => {
      res({ server, port: server.address().port });
    });
  });
}

test("summarize: success path returns assistant content", async (t) => {
  const { server, port } = await startStubSummarizer((_, response) => {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(
      JSON.stringify({
        choices: [{ message: { role: "assistant", content: "compressed" } }],
        usage: { prompt_tokens: 10, completion_tokens: 5 },
      }),
    );
  });
  t.after(() => new Promise((r) => server.close(() => r())));
  const out = await summarize(
    [{ role: "user", content: "huge body" }],
    { url: `http://127.0.0.1:${port}` },
  );
  assert.equal(out, "compressed");
});

test("summarize: empty url returns null (off mode)", async () => {
  const out = await summarize([{ role: "user", content: "x" }], { url: "" });
  assert.equal(out, null);
});

test("summarize: offline upstream returns null (graceful bypass)", async () => {
  // Use a port nothing listens on. Connection refused -> caught -> null.
  const out = await summarize(
    [{ role: "user", content: "x" }],
    { url: "http://127.0.0.1:1", timeoutMs: 500 },
  );
  assert.equal(out, null);
});

test("summarize: invalid JSON response returns null", async (t) => {
  const { server, port } = await startStubSummarizer((_, response) => {
    response.writeHead(200, { "content-type": "application/json" });
    response.end("<<not json>>");
  });
  t.after(() => new Promise((r) => server.close(() => r())));
  const out = await summarize(
    [{ role: "user", content: "x" }],
    { url: `http://127.0.0.1:${port}` },
  );
  assert.equal(out, null);
});

test("summarize: slow upstream times out and returns null", async (t) => {
  const { server, port } = await startStubSummarizer((_, response) => {
    // Hold the connection open longer than the timeout.
    setTimeout(() => {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(
        JSON.stringify({ choices: [{ message: { content: "late" } }] }),
      );
    }, 500);
  });
  t.after(() => new Promise((r) => server.close(() => r())));
  const start = Date.now();
  const out = await summarize(
    [{ role: "user", content: "x" }],
    { url: `http://127.0.0.1:${port}`, timeoutMs: 50 },
  );
  const elapsed = Date.now() - start;
  assert.equal(out, null);
  assert.ok(elapsed < 400, `expected timeout fast, took ${elapsed}ms`);
});

test("rewriteRequest: summarizer no-op when watermark not tripped", async () => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "summ-test-"));
  const big = "x".repeat(12000); // ~3000 tokens
  const body = {
    model: "stub",
    messages: [
      { role: "user", content: "hi" },
      {
        role: "assistant",
        content: null,
        tool_calls: [
          {
            id: "call_a",
            type: "function",
            function: { name: "Read", arguments: "{}" },
          },
        ],
      },
      { role: "tool", tool_call_id: "call_a", name: "Read", content: big },
      { role: "user", content: "now what" },
    ],
  };
  let summarizerCalls = 0;
  const fakeSummarize = async () => {
    summarizerCalls++;
    return "should not run";
  };
  const r = await rewriteRequest({
    body,
    tokenizer: makeTokenizer(),
    config: {
      watermarks: {
        prompt_fraction: 0.7,
        tool_result_min_tokens: 2000,
        max_messages: 40,
        max_age_turns: 20,
        verbatim_keep_turns: 0,
        verbatim_keep_tokens: 0,
      },
      summarizer: {
        url: "http://127.0.0.1:1",
        mode: "enforce",
        request_timeout_ms: 100,
      },
    },
    cacheDir,
    nCtx: 1_000_000, // huge ctx -> ratio < 0.7 -> watermark not tripped
    summarizeFn: fakeSummarize,
  });
  assert.equal(summarizerCalls, 0, "summarizer should not be called");
  assert.equal(r.stats.summarized_count, 0);
  // Tier 1 still elides the giant tool result (always-on, independent of wm).
  assert.equal(r.stats.elided_tool_result_ids.length, 1);
});

test("rewriteRequest: summarizer enforce replaces oversized tool result", async () => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "summ-test-"));
  const big = "x".repeat(12000); // ~3000 tokens, well above 2000 threshold
  const body = {
    model: "stub",
    messages: [
      { role: "user", content: "hi" },
      {
        role: "assistant",
        content: null,
        tool_calls: [
          {
            id: "call_a",
            type: "function",
            function: { name: "Read", arguments: "{}" },
          },
        ],
      },
      { role: "tool", tool_call_id: "call_a", name: "Read", content: big },
      { role: "user", content: "now what" },
    ],
  };
  let summarizerCalls = 0;
  const fakeSummarize = async () => {
    summarizerCalls++;
    return "tight summary";
  };
  const r = await rewriteRequest({
    body,
    tokenizer: makeTokenizer(),
    config: {
      watermarks: {
        prompt_fraction: 0.5,
        tool_result_min_tokens: 2000,
        max_messages: 40,
        max_age_turns: 20,
        verbatim_keep_turns: 0,
        verbatim_keep_tokens: 0,
      },
      summarizer: {
        url: "http://127.0.0.1:1",
        mode: "enforce",
        request_timeout_ms: 100,
      },
    },
    cacheDir,
    nCtx: 4000, // small ctx -> ratio crosses 0.5 -> watermark trips
    summarizeFn: fakeSummarize,
  });
  assert.equal(summarizerCalls, 1, "summarizer should be called once");
  assert.equal(r.stats.summarized_count, 1);
  // Because Phase 2 replaced the body with a short summary BEFORE Tier 1,
  // Tier 1 should no longer find anything to stub.
  assert.equal(r.stats.elided_tool_result_ids.length, 0);
  const toolMsg = r.rewrittenBody.messages[2];
  assert.match(toolMsg.content, /<tool_result_summary tool="Read">tight summary<\/tool_result_summary>/);
});

test("rewriteRequest: summarizer offline falls through to Tier 1 stub", async () => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "summ-test-"));
  const big = "x".repeat(12000);
  const body = {
    model: "stub",
    messages: [
      { role: "user", content: "hi" },
      {
        role: "assistant",
        content: null,
        tool_calls: [
          {
            id: "call_a",
            type: "function",
            function: { name: "Read", arguments: "{}" },
          },
        ],
      },
      { role: "tool", tool_call_id: "call_a", name: "Read", content: big },
      { role: "user", content: "now what" },
    ],
  };
  // Real summarize() with an unreachable url -> null, so we fall through.
  const r = await rewriteRequest({
    body,
    tokenizer: makeTokenizer(),
    config: {
      watermarks: {
        prompt_fraction: 0.5,
        tool_result_min_tokens: 2000,
        max_messages: 40,
        max_age_turns: 20,
        verbatim_keep_turns: 0,
        verbatim_keep_tokens: 0,
      },
      summarizer: {
        url: "http://127.0.0.1:1", // nothing listens here
        mode: "enforce",
        request_timeout_ms: 200,
      },
    },
    cacheDir,
    nCtx: 4000,
  });
  assert.equal(r.stats.summarized_count, 0);
  // Phase 2 bypassed -> Tier 1 still does its job.
  assert.equal(r.stats.elided_tool_result_ids.length, 1);
});
