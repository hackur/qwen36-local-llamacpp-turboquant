// Passthrough integration test against a stub upstream.
// Verifies:
//   - non-streaming POST /v1/chat/completions forwards bytes + status + headers
//   - streaming SSE is forwarded chunk-for-chunk including the [DONE] frame
//   - GET /v1/models and /health pass through
//   - x-compact: off is honoured (logged) and surfaces in response
//   - /proxy/info reports config + (mocked) n_ctx
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

function startStubUpstream() {
  return new Promise((res) => {
    const server = createServer((req, response) => {
      if (req.url === "/health") {
        response.writeHead(200, { "content-type": "text/plain" });
        response.end("ok");
        return;
      }
      if (req.url === "/v1/models") {
        response.writeHead(200, { "content-type": "application/json" });
        response.end(JSON.stringify({ data: [{ id: "stub" }] }));
        return;
      }
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
          // Stub: 1 token per 4 chars, minimum 1 if non-empty.
          const n = content.length === 0 ? 0 : Math.max(1, Math.ceil(content.length / 4));
          response.writeHead(200, { "content-type": "application/json" });
          response.end(JSON.stringify({ tokens: new Array(n).fill(0) }));
        });
        return;
      }
      if (req.url === "/v1/chat/completions" && req.method === "POST") {
        let body = "";
        req.on("data", (c) => (body += c));
        req.on("end", () => {
          const parsed = JSON.parse(body);
          if (parsed.stream) {
            response.writeHead(200, {
              "content-type": "text/event-stream",
              "cache-control": "no-cache",
            });
            response.write(
              `data: ${JSON.stringify({ choices: [{ delta: { content: "hi" } }] })}\n\n`,
            );
            response.write(
              `data: ${JSON.stringify({ choices: [{ delta: { content: " there" } }], usage: { prompt_tokens: 5, completion_tokens: 2 } })}\n\n`,
            );
            response.write("data: [DONE]\n\n");
            response.end();
          } else {
            response.writeHead(200, { "content-type": "application/json" });
            response.end(
              JSON.stringify({
                choices: [{ message: { role: "assistant", content: "hi" } }],
                usage: { prompt_tokens: 5, completion_tokens: 1 },
              }),
            );
          }
        });
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

async function startProxy({ upstreamPort, cacheDir }) {
  const logger = pino({ level: "silent" });
  const config = {
    listen: { host: "127.0.0.1", port: 0 },
    upstream: {
      base_url: `http://127.0.0.1:${upstreamPort}`,
      request_timeout_ms: 60000,
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
  return { server, jsonl, port: server.address().port, upstream };
}

test("passthrough end-to-end", async (t) => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "qwen-compact-test-"));
  const { server: stub, port: upstreamPort } = await startStubUpstream();
  const { server: proxy, jsonl, port: proxyPort, upstream } = await startProxy({
    upstreamPort,
    cacheDir,
  });
  t.after(
    () =>
      new Promise((r) => {
        proxy.close(() => stub.close(() => r()));
        jsonl.closeAll();
      }),
  );

  // 1. /health passthrough
  {
    const r = await fetch(`http://127.0.0.1:${proxyPort}/health`);
    assert.equal(r.status, 200);
    assert.equal(await r.text(), "ok");
    assert.ok(r.headers.get("x-proxy-request-id"));
  }

  // 2. /v1/models passthrough
  {
    const r = await fetch(`http://127.0.0.1:${proxyPort}/v1/models`);
    assert.equal(r.status, 200);
    const body = await r.json();
    assert.equal(body.data[0].id, "stub");
  }

  // 3. /proxy/info
  {
    const r = await fetch(`http://127.0.0.1:${proxyPort}/proxy/info`);
    assert.equal(r.status, 200);
    const body = await r.json();
    assert.equal(body.mode, "passthrough");
    assert.equal(body.n_ctx, 131072);
  }

  // 4. non-streaming chat completion
  {
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
    assert.ok(r.headers.get("x-proxy-request-id"));
  }

  // 5. streaming chat completion preserves SSE framing
  {
    const r = await fetch(`http://127.0.0.1:${proxyPort}/v1/chat/completions`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-compact": "off",
      },
      body: JSON.stringify({
        model: "stub",
        messages: [{ role: "user", content: "hi" }],
        stream: true,
      }),
    });
    assert.equal(r.status, 200);
    assert.equal(r.headers.get("x-compact"), "off");
    const text = await r.text();
    assert.ok(text.includes("data: "), "expected SSE data: frames");
    assert.ok(text.endsWith("data: [DONE]\n\n"), "expected terminal [DONE] frame");
    assert.ok(text.includes('"content":"hi"'));
    assert.ok(text.includes('"content":" there"'));
  }

  assert.equal(upstream.nCtx, 131072);
});
