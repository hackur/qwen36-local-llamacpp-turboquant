// End-to-end tool_calls coverage. Regression net for the proxy's ability to:
//   - forward a request with a `tools:[...]` definition unchanged to upstream
//   - stream tool_calls deltas back to the client byte-for-byte (no dropped
//     SSE frames, no merged/split chunks, no rewriting of function arguments)
//   - relay a non-streaming tool_calls response unchanged
//
// Mirrors the wiring used by passthrough.test.js / debug-rewrite.test.js so
// no new deps are needed (Node test runner + stdlib http only).
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import pino from "pino";

import { UpstreamClient } from "../src/upstream.js";
import { TokenizerClient } from "../src/tokenizer.js";
import { JsonlLogger } from "../src/jsonl-logger.js";
import { createProxyServer } from "../src/server.js";

// SSE chunks emitted by llama-server when the assistant emits a tool_call.
// The shape mirrors Qwen3.8 tool traffic: a leading
// role chunk, then several arguments deltas, then a finish_reason="tool_calls"
// chunk, then a usage frame, then [DONE].
const TOOL_CALL_CHUNKS = [
  `data: {"id":"c1","choices":[{"index":0,"delta":{"role":"assistant","content":null,"tool_calls":[{"index":0,"id":"call_abc","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}`,
  `data: {"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"loc"}}]}}]}`,
  `data: {"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ation"}}]}}]}`,
  `data: {"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\":\\"SF"}}]}}]}`,
  `data: {"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"}"}}]}}]}`,
  `data: {"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}`,
  `data: {"choices":[],"usage":{"completion_tokens":7,"prompt_tokens":120,"total_tokens":127,"prompt_tokens_details":{"cached_tokens":0}}}`,
  `data: [DONE]`,
];

function startStubUpstream({ onChat } = {}) {
  return new Promise((res) => {
    const server = createServer((req, response) => {
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
          const parsed = JSON.parse(body);
          if (onChat) onChat(parsed);
          if (parsed.stream) {
            response.writeHead(200, {
              "content-type": "text/event-stream",
              "cache-control": "no-cache",
            });
            // Write each SSE frame as a separate chunk so the proxy's
            // chunked iteration can be exercised.
            for (const c of TOOL_CALL_CHUNKS) {
              response.write(c + "\n\n");
            }
            response.end();
          } else {
            response.writeHead(200, { "content-type": "application/json" });
            response.end(
              JSON.stringify({
                choices: [
                  {
                    index: 0,
                    finish_reason: "tool_calls",
                    message: {
                      role: "assistant",
                      content: null,
                      tool_calls: [
                        {
                          id: "call_abc",
                          type: "function",
                          function: {
                            name: "get_weather",
                            arguments: '{"location":"SF"}',
                          },
                        },
                      ],
                    },
                  },
                ],
                usage: { prompt_tokens: 120, completion_tokens: 7 },
              }),
            );
          }
        });
        return;
      }
      response.writeHead(404);
      response.end();
    });
    server.listen(0, "127.0.0.1", () =>
      res({ server, port: server.address().port }),
    );
  });
}

async function startProxy({ upstreamPort, cacheDir, mode = "passthrough" }) {
  const logger = pino({ level: "silent" });
  const config = {
    listen: { host: "127.0.0.1", port: 0 },
    upstream: { base_url: `http://127.0.0.1:${upstreamPort}`, request_timeout_ms: 60000 },
    mode,
    watermarks: {
      prompt_fraction: 0.7,
      tool_result_min_tokens: 2000,
      max_messages: 40,
      max_age_turns: 20,
      verbatim_keep_turns: 8,
      verbatim_keep_tokens: 8000,
    },
    cache_dir: cacheDir,
    tokenizer: { cache_entries: 1024 },
    log_level: "silent",
  };
  const upstream = new UpstreamClient({ baseUrl: config.upstream.base_url, logger });
  await upstream.loadProps();
  const tokenizer = new TokenizerClient({
    baseUrl: config.upstream.base_url,
    cacheEntries: 1024,
    logger,
  });
  const jsonl = new JsonlLogger({ cacheDir });
  const server = createProxyServer({ config, upstream, tokenizer, jsonl, logger });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { server, jsonl, port: server.address().port };
}

const TOOL_DEFS = [
  {
    type: "function",
    function: {
      name: "get_weather",
      description: "Look up current weather for a city.",
      parameters: {
        type: "object",
        properties: { location: { type: "string" } },
        required: ["location"],
      },
    },
  },
];

test("tool_calls: tools array forwarded to upstream unmodified (non-streaming)", async (t) => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "tool-calls-test-"));
  let forwardedBody;
  const { server: stub, port: upstreamPort } = await startStubUpstream({
    onChat: (parsed) => (forwardedBody = parsed),
  });
  const { server: proxy, jsonl, port: proxyPort } = await startProxy({
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

  const r = await fetch(`http://127.0.0.1:${proxyPort}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: "stub",
      messages: [{ role: "user", content: "weather in SF?" }],
      tools: TOOL_DEFS,
    }),
  });
  assert.equal(r.status, 200);
  const body = await r.json();

  // Tool definition reaches upstream byte-equivalent.
  assert.deepEqual(forwardedBody.tools, TOOL_DEFS);

  // Response tool_calls relayed verbatim.
  const tc = body.choices[0].message.tool_calls[0];
  assert.equal(tc.id, "call_abc");
  assert.equal(tc.function.name, "get_weather");
  assert.equal(tc.function.arguments, '{"location":"SF"}');
  assert.equal(body.choices[0].finish_reason, "tool_calls");
});

test("tool_calls: streaming SSE deltas forwarded byte-for-byte (no dropped chunks)", async (t) => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "tool-calls-test-"));
  const { server: stub, port: upstreamPort } = await startStubUpstream();
  const { server: proxy, jsonl, port: proxyPort } = await startProxy({
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

  const r = await fetch(`http://127.0.0.1:${proxyPort}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: "stub",
      messages: [{ role: "user", content: "weather in SF?" }],
      tools: TOOL_DEFS,
      stream: true,
      stream_options: { include_usage: true },
    }),
  });
  assert.equal(r.status, 200);
  const text = await r.text();

  // All emitted SSE frames must appear, in order, exactly as the upstream
  // wrote them. This catches any future change that buffers/merges/rewrites
  // chunks on the streaming hot path.
  for (const c of TOOL_CALL_CHUNKS) {
    assert.ok(text.includes(c), `missing chunk: ${c.slice(0, 60)}...`);
  }
  // Order check: each chunk appears after the previous one.
  let cursor = 0;
  for (const c of TOOL_CALL_CHUNKS) {
    const at = text.indexOf(c, cursor);
    assert.ok(at >= cursor, `out-of-order or missing chunk: ${c.slice(0, 60)}`);
    cursor = at + c.length;
  }

  // Reassembling the function.arguments across deltas yields the original JSON.
  const argDeltas = [];
  for (const line of text.split(/\n+/)) {
    if (!line.startsWith("data: ")) continue;
    const payload = line.slice(6);
    if (payload === "[DONE]") continue;
    let obj;
    try {
      obj = JSON.parse(payload);
    } catch {
      continue;
    }
    const delta = obj?.choices?.[0]?.delta;
    const tcs = delta?.tool_calls;
    if (Array.isArray(tcs)) {
      for (const tc of tcs) {
        const a = tc?.function?.arguments;
        if (typeof a === "string" && a.length > 0) argDeltas.push(a);
      }
    }
  }
  assert.equal(argDeltas.join(""), '{"location":"SF"}');

  // Terminal frame intact.
  assert.ok(text.trimEnd().endsWith("data: [DONE]"));
});

test("tool_calls: subsequent tool reply round-trips with its tool_call_id", async (t) => {
  // The user-side flow: model emits tool_calls, harness runs the tool, then
  // posts a follow-up request including the original assistant message AND
  // a role:"tool" reply. The proxy must forward both unchanged so upstream
  // can correlate the call to its result. Regression net for any future
  // rewrite that strips/renames tool_call_id.
  const cacheDir = mkdtempSync(resolve(tmpdir(), "tool-calls-test-"));
  let forwardedBody;
  const { server: stub, port: upstreamPort } = await startStubUpstream({
    onChat: (parsed) => (forwardedBody = parsed),
  });
  const { server: proxy, jsonl, port: proxyPort } = await startProxy({
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

  const messages = [
    { role: "user", content: "weather in SF?" },
    {
      role: "assistant",
      content: null,
      tool_calls: [
        {
          id: "call_abc",
          type: "function",
          function: { name: "get_weather", arguments: '{"location":"SF"}' },
        },
      ],
    },
    {
      role: "tool",
      tool_call_id: "call_abc",
      name: "get_weather",
      content: '{"temp_f":68,"sky":"clear"}',
    },
  ];

  await fetch(`http://127.0.0.1:${proxyPort}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: "stub", messages, tools: TOOL_DEFS }),
  });

  // Assistant tool_calls preserved (id, name, arguments).
  const a = forwardedBody.messages.find((m) => m.role === "assistant");
  assert.ok(Array.isArray(a.tool_calls), "tool_calls preserved on assistant");
  assert.equal(a.tool_calls[0].id, "call_abc");
  assert.equal(a.tool_calls[0].function.name, "get_weather");
  assert.equal(a.tool_calls[0].function.arguments, '{"location":"SF"}');

  // Tool reply preserved (tool_call_id matches, content intact, small enough
  // to stay below tier1 min_tokens so it is NOT elided).
  const t1 = forwardedBody.messages.find((m) => m.role === "tool");
  assert.equal(t1.tool_call_id, "call_abc");
  assert.equal(t1.name, "get_weather");
  assert.equal(t1.content, '{"temp_f":68,"sky":"clear"}');
});
