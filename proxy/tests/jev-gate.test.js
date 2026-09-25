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
function history() {
  const m = [{ role: "system", content: "agent" }, { role: "user", content: "Find auth bug" }];
  for (let i = 0; i < 6; i++) {
    m.push({ role: "assistant", content: null, tool_calls: [{ id: `c${i}`, type: "function", function: { name: "Read", arguments: "{}" } }] });
    m.push({ role: "tool", tool_call_id: `c${i}`, name: "Read", content: "DATA " + "x".repeat(4000) });
  }
  m.push({ role: "user", content: "summarize and continue" });
  return m;
}
test("RED: jev compact forces frequent elision under watermark", async (t) => {
  const { server, port } = await stubJev((_, r) => {
    r.writeHead(200, { "content-type": "application/json" });
    r.end(JSON.stringify({ answers: { needs_thinking: { noul: 0.4 }, route: { choice: "compact", confidence: 0.85 }, risk: { score: 0 } } }));
  });
  t.after(() => new Promise((r) => server.close(() => r())));
  const cacheDir = mkdtempSync(resolve(tmpdir(), "jevgate-"));
  const r = await rewriteRequest({
    body: { model: "s", messages: history() }, tokenizer: makeDemoTokenizer(), cacheDir, nCtx: 1000000,
    config: { watermarks: { prompt_fraction: 0.9, tool_result_min_tokens: 5000, max_messages: 100, max_age_turns: 50, verbatim_keep_turns: 8, verbatim_keep_tokens: 8000 }, jev: { local_url: `http://127.0.0.1:${port}`, mode: "local-only", timeout_ms: 1500 } },
  });
  function makeDemoTokenizer() { return makeTokenizer(); }
  assert.ok(r.stats.elided_tool_result_ids.length >= 3, `expected jev-forced elision, got ${r.stats.elided_tool_result_ids.length}`);
});
