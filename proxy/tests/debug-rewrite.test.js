// x-debug-rewritten contract integration tests.
// Verifies:
//   - debug header → no upstream call, 200 with stats headers
//   - small rewrite → x-rewritten-messages inline header
//   - large rewrite → x-rewritten-sidecar with file path
//   - elided_tool_result_ids includes the elided id
//   - x-compact: off bypasses rewriting even with debug header
//   - shadow mode forwards original; enforce mode forwards rewritten
import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import pino from "pino";

import { UpstreamClient } from "../src/upstream.js";
import { TokenizerClient } from "../src/tokenizer.js";
import { JsonlLogger } from "../src/jsonl-logger.js";
import { createProxyServer } from "../src/server.js";

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
          response.writeHead(200, { "content-type": "application/json" });
          response.end(
            JSON.stringify({
              choices: [{ message: { role: "assistant", content: "ok" } }],
              usage: { prompt_tokens: 1, completion_tokens: 1 },
            }),
          );
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
      verbatim_keep_turns: 2,
      verbatim_keep_tokens: 0,
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

function buildSession({ bigContent }) {
  // 4 turns + tool result. With keepTurns=2, the early tool result becomes
  // evictable and gets elided when over min_tokens.
  return [
    { role: "system", content: "sys" },
    {
      role: "assistant",
      content: null,
      tool_calls: [
        {
          id: "call_a",
          type: "function",
          function: { name: "Read", arguments: '{"path":"foo.py"}' },
        },
      ],
    },
    { role: "tool", tool_call_id: "call_a", name: "Read", content: bigContent },
    { role: "assistant", content: "got it" },
    { role: "user", content: "next" },
  ];
}

test("debug-rewrite: inline header for small rewrite, no upstream call", async (t) => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "qwen-compact-test-"));
  let upstreamCalls = 0;
  const { server: stub, port: upstreamPort } = await startStubUpstream({
    onChat: () => upstreamCalls++,
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

  const big = "x".repeat(12000);
  const r = await fetch(`http://127.0.0.1:${proxyPort}/v1/chat/completions`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-debug-rewritten": "1",
    },
    body: JSON.stringify({ model: "stub", messages: buildSession({ bigContent: big }) }),
  });
  assert.equal(r.status, 200);
  assert.equal(await r.text(), "{}");
  assert.equal(upstreamCalls, 0, "upstream must not be called in debug mode");

  const stats = JSON.parse(r.headers.get("x-rewrite-stats"));
  assert.ok(stats.orig_tokens > stats.rewritten_tokens);
  assert.deepEqual(stats.elided_tool_result_ids, ["call_a"]);

  const inline = r.headers.get("x-rewritten-messages");
  assert.ok(inline, "expected inline header for small rewrite");
  const messages = JSON.parse(inline);
  assert.match(messages[2].content, /^<tool_result id="call_a"/);
});

test("debug-rewrite: sidecar path when payload exceeds inline budget", async (t) => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "qwen-compact-test-"));
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

  // Make the rewritten messages array itself big — many small kept turns
  // each with a kilobyte of content. None individually elidable (under
  // min_tokens) but the rewritten array overflows the 6KB inline budget.
  const messages = [{ role: "system", content: "sys" }];
  for (let i = 0; i < 10; i++) {
    messages.push({ role: "user", content: "a".repeat(800) });
    messages.push({ role: "assistant", content: "b".repeat(800) });
  }
  messages.push({ role: "user", content: "tail" });

  const r = await fetch(`http://127.0.0.1:${proxyPort}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-debug-rewritten": "1" },
    body: JSON.stringify({ model: "stub", messages }),
  });
  assert.equal(r.status, 200);
  assert.equal(r.headers.get("x-rewritten-messages"), null);
  const sidecar = r.headers.get("x-rewritten-sidecar");
  assert.ok(sidecar, "expected sidecar path");
  const written = JSON.parse(readFileSync(sidecar, "utf8"));
  assert.ok(Array.isArray(written));
});

test("debug-rewrite: x-compact: off bypasses rewriting (no headers, forwards)", async (t) => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "qwen-compact-test-"));
  let upstreamCalls = 0;
  const { server: stub, port: upstreamPort } = await startStubUpstream({
    onChat: () => upstreamCalls++,
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
    headers: {
      "content-type": "application/json",
      "x-compact": "off",
      "x-debug-rewritten": "1",
    },
    body: JSON.stringify({
      model: "stub",
      messages: buildSession({ bigContent: "x".repeat(12000) }),
    }),
  });
  // x-compact:off → no rewrite computed → debug header is ignored, normal
  // forwarding occurs.
  assert.equal(r.status, 200);
  assert.equal(upstreamCalls, 1);
  assert.equal(r.headers.get("x-rewrite-stats"), null);
});

test("modes: shadow forwards original, enforce forwards rewritten", async (t) => {
  // Shadow run.
  {
    const cacheDir = mkdtempSync(resolve(tmpdir(), "qwen-compact-test-"));
    let forwardedBody;
    const { server: stub, port: upstreamPort } = await startStubUpstream({
      onChat: (parsed) => (forwardedBody = parsed),
    });
    const { server: proxy, jsonl, port: proxyPort } = await startProxy({
      upstreamPort,
      cacheDir,
      mode: "shadow",
    });
    t.after(
      () =>
        new Promise((r) => {
          proxy.close(() => stub.close(() => r()));
          jsonl.closeAll();
        }),
    );
    const big = "x".repeat(12000);
    await fetch(`http://127.0.0.1:${proxyPort}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ model: "stub", messages: buildSession({ bigContent: big }) }),
    });
    // Shadow mode: original tool content forwarded verbatim.
    assert.equal(forwardedBody.messages[2].content, big);
  }

  // Enforce run.
  {
    const cacheDir = mkdtempSync(resolve(tmpdir(), "qwen-compact-test-"));
    let forwardedBody;
    const { server: stub, port: upstreamPort } = await startStubUpstream({
      onChat: (parsed) => (forwardedBody = parsed),
    });
    const { server: proxy, jsonl, port: proxyPort } = await startProxy({
      upstreamPort,
      cacheDir,
      mode: "enforce",
    });
    t.after(
      () =>
        new Promise((r) => {
          proxy.close(() => stub.close(() => r()));
          jsonl.closeAll();
        }),
    );
    const big = "x".repeat(12000);
    await fetch(`http://127.0.0.1:${proxyPort}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ model: "stub", messages: buildSession({ bigContent: big }) }),
    });
    // Enforce mode: tool content was elided to a stub; expand_tool_result
    // tool def appended.
    assert.match(forwardedBody.messages[2].content, /^<tool_result id="call_a"/);
    const tools = forwardedBody.tools || [];
    const expand = tools.find((t) => t?.function?.name === "expand_tool_result");
    assert.ok(expand, "expected expand_tool_result tool to be injected");
  }
});

test("phantom expand_tool_result: proxy answers locally without upstream", async (t) => {
  const cacheDir = mkdtempSync(resolve(tmpdir(), "qwen-compact-test-"));
  let forwardedBody;
  const { server: stub, port: upstreamPort } = await startStubUpstream({
    onChat: (parsed) => (forwardedBody = parsed),
  });
  const { server: proxy, jsonl, port: proxyPort } = await startProxy({
    upstreamPort,
    cacheDir,
    mode: "enforce",
  });
  t.after(
    () =>
      new Promise((r) => {
        proxy.close(() => stub.close(() => r()));
        jsonl.closeAll();
      }),
  );

  // First request elides a tool result and persists call_a.json.
  const big = "VERBATIM-CONTENT-" + "x".repeat(12000);
  await fetch(`http://127.0.0.1:${proxyPort}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: "stub", messages: buildSession({ bigContent: big }) }),
  });

  // Now the model "calls" expand_tool_result. The harness sends an assistant
  // message with the call but no matching tool reply yet. Proxy should
  // intercept and splice the verbatim back in.
  const followup = [
    { role: "system", content: "sys" },
    { role: "user", content: "earlier" },
    {
      role: "assistant",
      content: null,
      tool_calls: [
        {
          id: "expand_1",
          type: "function",
          function: {
            name: "expand_tool_result",
            arguments: JSON.stringify({ id: "call_a" }),
          },
        },
      ],
    },
  ];
  await fetch(`http://127.0.0.1:${proxyPort}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: "stub", messages: followup }),
  });

  // The forwarded body should now have a synthesised tool message answering
  // expand_1 with the verbatim original.
  const toolMsg = forwardedBody.messages.find(
    (m) => m.role === "tool" && m.tool_call_id === "expand_1",
  );
  assert.ok(toolMsg, "expected proxy-synthesized tool reply");
  assert.match(toolMsg.content, /VERBATIM-CONTENT-/);
});

test("phantom expand_tool_result: bash-read-shaped payload rehydrates byte-exact", async (t) => {
  // Edge case: a realistic Bash/Read tool result (multi-line, with quotes,
  // braces and angle-brackets that would otherwise confuse the stub format).
  // Verifies the rehydrated content matches the original byte-for-byte and
  // that elision happens past the watermark (tool_result_min_tokens=2000).
  const cacheDir = mkdtempSync(resolve(tmpdir(), "qwen-compact-test-"));
  let forwardedBody;
  const { server: stub, port: upstreamPort } = await startStubUpstream({
    onChat: (parsed) => (forwardedBody = parsed),
  });
  const { server: proxy, jsonl, port: proxyPort } = await startProxy({
    upstreamPort,
    cacheDir,
    mode: "enforce",
  });
  t.after(
    () =>
      new Promise((r) => {
        proxy.close(() => stub.close(() => r()));
        jsonl.closeAll();
      }),
  );

  // Build a long, realistic-ish bash output that includes characters the
  // stub would otherwise need to escape: quotes, `<`, `>`, `&`, newlines,
  // and JSON-looking braces. ~16K chars → ~4K tokens (above 2000 watermark).
  const tricky = [
    `$ cat /etc/hosts`,
    `127.0.0.1 localhost`,
    `::1 localhost`,
    `# comment with "quotes" & <html> tags`,
    `{ "json": "looking", "value": [1,2,3] }`,
    `</tool_result>  -- adversarial close tag`,
  ].join("\n");
  const big = (tricky + "\n").repeat(400); // > min_tokens
  assert.ok(big.length > 8000);

  // Step 1: send the big tool result through enforce mode → proxy elides &
  // persists call_bash.json under cache_dir/tool-results/.
  const initialMessages = [
    { role: "system", content: "sys" },
    {
      role: "assistant",
      content: null,
      tool_calls: [
        {
          id: "call_bash",
          type: "function",
          function: { name: "Bash", arguments: '{"cmd":"cat /etc/hosts"}' },
        },
      ],
    },
    { role: "tool", tool_call_id: "call_bash", name: "Bash", content: big },
    { role: "assistant", content: "ack" },
    { role: "user", content: "next" },
  ];
  await fetch(`http://127.0.0.1:${proxyPort}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: "stub", messages: initialMessages }),
  });

  // Confirm elision actually happened on the wire.
  const elidedToolMsg = forwardedBody.messages.find(
    (m) => m.role === "tool" && m.tool_call_id === "call_bash",
  );
  assert.ok(elidedToolMsg, "tool message present");
  assert.match(elidedToolMsg.content, /^<tool_result id="call_bash"/);
  assert.notEqual(elidedToolMsg.content, big, "content was elided");

  // Step 2: model "calls" expand_tool_result. Proxy answers locally.
  const followup = [
    { role: "system", content: "sys" },
    { role: "user", content: "show me hosts file" },
    {
      role: "assistant",
      content: null,
      tool_calls: [
        {
          id: "expand_call_bash",
          type: "function",
          function: {
            name: "expand_tool_result",
            arguments: JSON.stringify({ id: "call_bash" }),
          },
        },
      ],
    },
  ];
  await fetch(`http://127.0.0.1:${proxyPort}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: "stub", messages: followup }),
  });

  const rehydrated = forwardedBody.messages.find(
    (m) => m.role === "tool" && m.tool_call_id === "expand_call_bash",
  );
  assert.ok(rehydrated, "expected proxy-synthesized expand reply");
  // Byte-exact rehydration of the full original payload.
  assert.equal(rehydrated.content, big, "rehydrated content matches original byte-for-byte");
});

test("phantom expand_tool_result: unknown id returns local error envelope, not upstream", async (t) => {
  // Edge case: the model hallucinates an id that was never persisted. The
  // proxy must answer locally with an error envelope so the request still
  // resolves; it must NOT forward the unanswered tool_call to upstream
  // (which would otherwise reject the prompt for a missing tool reply).
  const cacheDir = mkdtempSync(resolve(tmpdir(), "qwen-compact-test-"));
  let forwardedBody;
  const { server: stub, port: upstreamPort } = await startStubUpstream({
    onChat: (parsed) => (forwardedBody = parsed),
  });
  const { server: proxy, jsonl, port: proxyPort } = await startProxy({
    upstreamPort,
    cacheDir,
    mode: "enforce",
  });
  t.after(
    () =>
      new Promise((r) => {
        proxy.close(() => stub.close(() => r()));
        jsonl.closeAll();
      }),
  );

  const followup = [
    { role: "system", content: "sys" },
    { role: "user", content: "fetch something" },
    {
      role: "assistant",
      content: null,
      tool_calls: [
        {
          id: "expand_ghost",
          type: "function",
          function: {
            name: "expand_tool_result",
            arguments: JSON.stringify({ id: "never_persisted_id" }),
          },
        },
      ],
    },
  ];
  await fetch(`http://127.0.0.1:${proxyPort}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ model: "stub", messages: followup }),
  });

  const synth = forwardedBody.messages.find(
    (m) => m.role === "tool" && m.tool_call_id === "expand_ghost",
  );
  assert.ok(synth, "proxy must synthesize a tool reply even on unknown id");
  const parsed = JSON.parse(synth.content);
  assert.match(parsed.error, /unknown id/);
  assert.match(parsed.error, /never_persisted_id/);
});
