// Verifies that `upstream.request_timeout_ms` is wired through to the chat
// fetch in server.js. Uses the same in-process Node http stub-upstream
// pattern as passthrough.test.js.
//
// Three cases:
//   1. Non-streaming hang: stub never responds — proxy must return 504 within
//      timeout + slack.
//   2. Streaming hang: stub starts SSE then sits forever — proxy must abort
//      and emit a clean `data: [DONE]\n\n` terminator.
//   3. Happy path: stub responds in time — timer is cleared, response is
//      forwarded byte-identical.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import pino from "pino";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

import { UpstreamClient } from "../src/upstream.js";
import { TokenizerClient } from "../src/tokenizer.js";
import { JsonlLogger } from "../src/jsonl-logger.js";
import { createProxyServer } from "../src/server.js";

// Stub upstream with a configurable behavior for /v1/chat/completions.
// behavior: "hang" — never respond at all
//           "stream-hang" — write a few SSE frames then never end
//           "ok" / "ok-stream" — normal response
function startStubUpstream(behavior) {
  const openSockets = new Set();
  return new Promise((res) => {
    const server = createServer((req, response) => {
      response.socket && openSockets.add(response.socket);
      response.socket?.on("close", () => openSockets.delete(response.socket));

      if (req.url === "/props") {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ n_ctx: 131072 }));
        return;
      }
      if (req.url === "/tokenize" && req.method === "POST") {
        let body = "";
        req.on("data", (c) => (body += c));
        req.on("end", () => {
          const { content = "" } = JSON.parse(body || "{}");
          const n =
            content.length === 0 ? 0 : Math.max(1, Math.ceil(content.length / 4));
          response.writeHead(200, { "content-type": "application/json" });
          response.end(JSON.stringify({ tokens: new Array(n).fill(0) }));
        });
        return;
      }
      if (req.url === "/v1/chat/completions" && req.method === "POST") {
        let body = "";
        req.on("data", (c) => (body += c));
        req.on("end", () => {
          if (behavior === "hang") {
            // Read the request, then never respond.
            return;
          }
          if (behavior === "stream-hang") {
            response.writeHead(200, {
              "content-type": "text/event-stream",
              "cache-control": "no-cache",
            });
            response.write(
              `data: ${JSON.stringify({ choices: [{ delta: { content: "hi" } }] })}\n\n`,
            );
            // Then sit forever — no [DONE], no end.
            return;
          }
          if (behavior === "ok-stream") {
            response.writeHead(200, {
              "content-type": "text/event-stream",
              "cache-control": "no-cache",
            });
            response.write(
              `data: ${JSON.stringify({ choices: [{ delta: { content: "hi" } }] })}\n\n`,
            );
            response.write("data: [DONE]\n\n");
            response.end();
            return;
          }
          // ok
          response.writeHead(200, { "content-type": "application/json" });
          response.end(
            JSON.stringify({
              choices: [{ message: { role: "assistant", content: "hi" } }],
              usage: { prompt_tokens: 5, completion_tokens: 1 },
            }),
          );
        });
        return;
      }
      response.writeHead(404);
      response.end();
    });
    server.listen(0, "127.0.0.1", () => {
      res({
        server,
        port: server.address().port,
        // Force-close any half-open sockets left over from "hang" / "stream-hang".
        forceClose() {
          for (const s of openSockets) {
            try { s.destroy(); } catch { /* ignore */ }
          }
        },
      });
    });
  });
}

async function startProxy({ upstreamPort, cacheDir, requestTimeoutMs }) {
  const logger = pino({ level: "silent" });
  const config = {
    listen: { host: "127.0.0.1", port: 0 },
    upstream: {
      base_url: `http://127.0.0.1:${upstreamPort}`,
      request_timeout_ms: requestTimeoutMs,
    },
    mode: "passthrough",
    watermarks: {
      prompt_fraction: 0.7,
      tool_result_min_tokens: 2000,
      max_messages: 40,
      max_age_turns: 20,
    },
    cache_dir: cacheDir,
    tokenizer: { cache_entries: 64 },
    log_level: "silent",
  };
  const upstream = new UpstreamClient({ baseUrl: config.upstream.base_url, logger });
  await upstream.loadProps();
  const tokenizer = new TokenizerClient({
    baseUrl: config.upstream.base_url,
    cacheEntries: 64,
    logger,
  });
  const jsonl = new JsonlLogger({ cacheDir });
  const server = createProxyServer({ config, upstream, tokenizer, jsonl, logger });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { server, jsonl, port: server.address().port };
}

test("non-streaming: hung upstream returns 504 within timeout + slack", async (t) => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "qwen-compact-test-"));
  const stub = await startStubUpstream("hang");
  const { server: proxy, jsonl, port: proxyPort } = await startProxy({
    upstreamPort: stub.port,
    cacheDir,
    requestTimeoutMs: 200,
  });
  t.after(
    () =>
      new Promise((r) => {
        stub.forceClose();
        proxy.close(() => stub.server.close(() => r()));
        jsonl.closeAll();
      }),
  );

  const t0 = Date.now();
  const r = await fetch(`http://127.0.0.1:${proxyPort}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: "stub",
      messages: [{ role: "user", content: "hello" }],
    }),
  });
  const elapsed = Date.now() - t0;
  assert.equal(r.status, 504);
  const body = await r.json();
  assert.equal(body.error.type, "upstream_timeout");
  assert.match(body.error.message, /200ms/);
  // Should fire close to the configured timeout, with generous slack for CI.
  assert.ok(
    elapsed >= 150 && elapsed < 3000,
    `expected ~200ms, got ${elapsed}ms`,
  );
});

test("streaming: hung upstream mid-stream emits clean [DONE] terminator", async (t) => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "qwen-compact-test-"));
  const stub = await startStubUpstream("stream-hang");
  const { server: proxy, jsonl, port: proxyPort } = await startProxy({
    upstreamPort: stub.port,
    cacheDir,
    requestTimeoutMs: 200,
  });
  t.after(
    () =>
      new Promise((r) => {
        stub.forceClose();
        proxy.close(() => stub.server.close(() => r()));
        jsonl.closeAll();
      }),
  );

  const r = await fetch(`http://127.0.0.1:${proxyPort}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: "stub",
      messages: [{ role: "user", content: "hi" }],
      stream: true,
    }),
  });
  // Stream begins fine — headers were flushed before timeout.
  assert.equal(r.status, 200);
  const text = await r.text();
  assert.ok(text.includes('"content":"hi"'), "expected first SSE frame");
  assert.ok(
    text.endsWith("data: [DONE]\n\n"),
    `expected clean [DONE] terminator after timeout, got: ${JSON.stringify(text.slice(-40))}`,
  );
});

test("happy path: timeout doesn't fire when upstream responds normally", async (t) => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "qwen-compact-test-"));
  const stub = await startStubUpstream("ok");
  const { server: proxy, jsonl, port: proxyPort } = await startProxy({
    upstreamPort: stub.port,
    cacheDir,
    requestTimeoutMs: 5000,
  });
  t.after(
    () =>
      new Promise((r) => {
        proxy.close(() => stub.server.close(() => r()));
        jsonl.closeAll();
      }),
  );

  const r = await fetch(`http://127.0.0.1:${proxyPort}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: "stub",
      messages: [{ role: "user", content: "hello" }],
    }),
  });
  assert.equal(r.status, 200);
  const body = await r.json();
  assert.equal(body.choices[0].message.content, "hi");
  assert.equal(body.usage.completion_tokens, 1);
});
