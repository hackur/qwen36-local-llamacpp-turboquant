import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { rewriteRequest } from "../src/rewrite.js";
import { LRU } from "../src/lru.js";

function makeTokenizer() {
  const cache = new LRU(1024);
  return { cache, async countTokens(t) { if (!t) return 0; const h = cache.get(t); if (typeof h === "number") return h; const n = Math.max(1, Math.ceil(String(t).length / 4)); cache.set(t, n); return n; } };
}

function stubJev(handler) {
  return new Promise((res) => {
    const s = createServer((req, r) => {
      if (req.url === "/v1/systemone" && req.method === "POST") { let b = ""; req.on("data", (c) => (b += c)); req.on("end", () => handler(JSON.parse(b), r)); return; }
      r.writeHead(404); r.end();
    });
    s.listen(0, "127.0.0.1", () => res({ server: s, port: s.address().port }));
  });
}

function tool(name) {
  return { type: "function", function: { name, description: `do ${name}`, parameters: { type: "object", properties: {} } } };
}

const TOOLS = [tool("Read"), tool("Grep"), tool("Bash"), tool("Edit"), tool("Fetch")];

const TAXONOMY = {
  search: ["Read", "Grep"],
  shell: ["Bash"],
  browse: ["Fetch"],
};

function baseConfig(jevCfg, filterCfg) {
  return {
    watermarks: { prompt_fraction: 0.9, tool_result_min_tokens: 5000, max_messages: 100, max_age_turns: 50, verbatim_keep_turns: 8, verbatim_keep_tokens: 8000 },
    jev: jevCfg,
    tool_filter: filterCfg,
  };
}

async function run(body, config, handler) {
  const { server, port } = await stubJev(handler);
  try {
    return await rewriteRequest({
      body, tokenizer: makeTokenizer(),
      cacheDir: mkdtempSync(resolve(tmpdir(), "toolfilt-")),
      nCtx: 1000000, config,
    });
  } finally {
    await new Promise((r) => server.close(() => r()));
  }
}

function respond(answers) {
  return (b, r) => {
    r.writeHead(200, { "content-type": "application/json" });
    r.end(JSON.stringify({ answers }));
  };
}

test("shadow: high-confidence toolset is recorded but tools are NOT dropped", async () => {
  const r = await run(
    { model: "s", messages: [{ role: "user", content: "find the config" }], tools: TOOLS },
    baseConfig(
      { local_url: "http://127.0.0.1:1", model: "typed-decisions", mode: "local-only", timeout_ms: 300 },
      { mode: "shadow", confidence: 0.6, taxonomy: TAXONOMY, timeout_ms: 300 }
    ),
    respond({
      needs_thinking: { noul: 0.1 },
      route: { choice: "local_direct", confidence: 0.9 },
      risk: { score: 0 },
      toolset: { choice: "search", confidence: 0.8 },
    })
  );
  assert.ok(r.stats.tool_filter, "tool_filter stats present");
  assert.equal(r.stats.tool_filter.choice, "search");
  assert.equal(r.stats.tool_filter.passes, true);
  assert.deepEqual(r.stats.tool_filter.selected, ["Read", "Grep"]);
  assert.deepEqual(r.stats.tool_filter.dropped, ["Bash", "Edit", "Fetch"]);
  const names = r.rewrittenBody.tools.map((t) => t.function.name);
  assert.deepEqual(names, TOOLS.map((t) => t.function.name), "shadow must not drop tools");
});

test("enforce: high-confidence toolset drops unselected tools", async () => {
  const r = await run(
    { model: "s", messages: [{ role: "user", content: "find the config" }], tools: TOOLS },
    baseConfig(
      { local_url: "http://127.0.0.1:1", model: "typed-decisions", mode: "local-only", timeout_ms: 300 },
      { mode: "enforce", confidence: 0.6, taxonomy: TAXONOMY, timeout_ms: 300 }
    ),
    respond({
      needs_thinking: { noul: 0.1 },
      route: { choice: "local_direct", confidence: 0.9 },
      risk: { score: 0 },
      toolset: { choice: "search", confidence: 0.8 },
    })
  );
  assert.equal(r.stats.tool_filter.passes, true);
  const names = r.rewrittenBody.tools.map((t) => t.function.name);
  assert.deepEqual(names, ["Read", "Grep"]);
});

test("low confidence: no filtering, passthrough", async () => {
  const r = await run(
    { model: "s", messages: [{ role: "user", content: "find the config" }], tools: TOOLS },
    baseConfig(
      { local_url: "http://127.0.0.1:1", model: "typed-decisions", mode: "local-only", timeout_ms: 300 },
      { mode: "enforce", confidence: 0.6, taxonomy: TAXONOMY, timeout_ms: 300 }
    ),
    respond({
      needs_thinking: { noul: 0.1 },
      route: { choice: "local_direct", confidence: 0.9 },
      risk: { score: 0 },
      toolset: { choice: "search", confidence: 0.2 },
    })
  );
  assert.equal(r.stats.tool_filter.passes, false);
  const names = r.rewrittenBody.tools.map((t) => t.function.name);
  assert.deepEqual(names, TOOLS.map((t) => t.function.name));
});

test("unknown label: no filtering", async () => {
  const r = await run(
    { model: "s", messages: [{ role: "user", content: "find the config" }], tools: TOOLS },
    baseConfig(
      { local_url: "http://127.0.0.1:1", model: "typed-decisions", mode: "local-only", timeout_ms: 300 },
      { mode: "enforce", confidence: 0.6, taxonomy: TAXONOMY, timeout_ms: 300 }
    ),
    respond({
      needs_thinking: { noul: 0.1 },
      route: { choice: "local_direct", confidence: 0.9 },
      risk: { score: 0 },
      toolset: { choice: "quantum", confidence: 0.99 },
    })
  );
  assert.equal(r.stats.tool_filter.passes, false);
  const names = r.rewrittenBody.tools.map((t) => t.function.name);
  assert.deepEqual(names, TOOLS.map((t) => t.function.name));
});

test("choice all: passes, nothing dropped", async () => {
  const r = await run(
    { model: "s", messages: [{ role: "user", content: "do everything" }], tools: TOOLS },
    baseConfig(
      { local_url: "http://127.0.0.1:1", model: "typed-decisions", mode: "local-only", timeout_ms: 300 },
      { mode: "enforce", confidence: 0.6, taxonomy: TAXONOMY, timeout_ms: 300 }
    ),
    respond({
      needs_thinking: { noul: 0.9 },
      route: { choice: "local_think", confidence: 0.9 },
      risk: { score: 0 },
      toolset: { choice: "all", confidence: 0.9 },
    })
  );
  assert.equal(r.stats.tool_filter.passes, true);
  assert.deepEqual(r.stats.tool_filter.dropped, []);
  const names = r.rewrittenBody.tools.map((t) => t.function.name);
  assert.deepEqual(names, TOOLS.map((t) => t.function.name));
});

test("no tools in body: no filter applied", async () => {
  const r = await run(
    { model: "s", messages: [{ role: "user", content: "find the config" }] },
    baseConfig(
      { local_url: "http://127.0.0.1:1", model: "typed-decisions", mode: "local-only", timeout_ms: 300 },
      { mode: "enforce", confidence: 0.6, taxonomy: TAXONOMY, timeout_ms: 300 }
    ),
    respond({
      needs_thinking: { noul: 0.1 },
      route: { choice: "local_direct", confidence: 0.9 },
      risk: { score: 0 },
      toolset: { choice: "search", confidence: 0.9 },
    })
  );
  assert.equal(r.stats.tool_filter, null);
});

test("classifier failure: fails open, no filter", async () => {
  const r = await run(
    { model: "s", messages: [{ role: "user", content: "find the config" }], tools: TOOLS },
    baseConfig(
      { local_url: "http://127.0.0.1:1", model: "typed-decisions", mode: "local-only", timeout_ms: 300 },
      { mode: "enforce", confidence: 0.6, taxonomy: TAXONOMY, timeout_ms: 300 }
    ),
    (b, resp) => { resp.writeHead(500); resp.end("boom"); }
  );
  // Classifier down: fail-open — no choice, nothing dropped, original tools kept.
  assert.ok(r.stats.tool_filter, "tool_filter recorded");
  assert.equal(r.stats.tool_filter.passes, false);
  assert.deepEqual(r.stats.tool_filter.dropped, []);
  const names = r.rewrittenBody.tools.map((t) => t.function.name);
  assert.deepEqual(names, TOOLS.map((t) => t.function.name));
});

test("taxonomy labels may point at all via `all` string", async () => {
  const r = await run(
    { model: "s", messages: [{ role: "user", content: "go" }], tools: TOOLS },
    baseConfig(
      { local_url: "http://127.0.0.1:1", model: "typed-decisions", mode: "local-only", timeout_ms: 300 },
      { mode: "enforce", confidence: 0.6, taxonomy: { big: "all" }, timeout_ms: 300 }
    ),
    respond({
      needs_thinking: { noul: 0.1 },
      route: { choice: "local_direct", confidence: 0.9 },
      risk: { score: 0 },
      toolset: { choice: "big", confidence: 0.9 },
    })
  );
  // "all" as a label maps to every tool, i.e. no drop.
  assert.equal(r.stats.tool_filter.passes, true);
  assert.deepEqual(r.stats.tool_filter.dropped, []);
  const names = r.rewrittenBody.tools.map((t) => t.function.name);
  assert.deepEqual(names, TOOLS.map((t) => t.function.name));
});
