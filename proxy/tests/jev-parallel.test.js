import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { jevEvaluate, routeLocalRequest } from "../src/jev.js";
function stub(handler) {
  return new Promise((res) => {
    const server = createServer((req, response) => {
      if (req.url === "/v1/systemone" && req.method === "POST") {
        let body = "";
        req.on("data", (c) => (body += c));
        req.on("end", () => handler(JSON.parse(body), response));
        return;
      }
      response.writeHead(404);
      response.end();
    });
    server.listen(0, "127.0.0.1", () => res({ server, port: server.address().port }));
  });
}
const Q = (extra = {}) => ({
  route: { type: "choice", instructions: "Pick handler", criteria: { local_direct: "lookup", local_think: "reason", compact: "summarize" }, ...extra },
});
test("1 local-first billing triage hits local, no cloud", async (t) => {
  const { server, port } = await stub((_, r) => {
    r.writeHead(200, { "content-type": "application/json" });
    r.end(JSON.stringify({ answers: { route: { choice: "local_direct", confidence: 0.94 } } }));
  });
  t.after(() => new Promise((r) => server.close(() => r())));
  const out = await jevEvaluate({ subject: "Duplicate charge #4411" }, Q(), { localUrl: `http://127.0.0.1:${port}`, mode: "local-first", timeoutMs: 2000 });
  assert.equal(out.answers.route.choice, "local_direct");
  assert.equal(out._source, "local");
});
test("2 local offline falls back to cloud", async (t) => {
  const { server, port } = await stub((_, r) => {
    r.writeHead(200, { "content-type": "application/json" });
    r.end(JSON.stringify({ answers: { route: { choice: "local_think", confidence: 0.88 } } }));
  });
  t.after(() => new Promise((r) => server.close(() => r())));
  const out = await jevEvaluate({ document: "arch debug" }, Q(), { localUrl: "http://127.0.0.1:1", cloudUrl: `http://127.0.0.1:${port}`, apiKey: "k", mode: "local-first", timeoutMs: 800 });
  assert.equal(out._source, "cloud");
  assert.equal(out.answers.route.choice, "local_think");
});
test("3 both offline fail-open null, proxy continues", async () => {
  const out = await jevEvaluate({ document: "x" }, Q(), { localUrl: "http://127.0.0.1:1", apiKey: "k", cloudUrl: "http://127.0.0.1:1", mode: "local-first", timeoutMs: 300 });
  assert.equal(out, null);
  const noKey = await jevEvaluate({ document: "x" }, Q(), { localUrl: "http://127.0.0.1:1", apiKey: "", mode: "local-only", timeoutMs: 300 });
  assert.equal(noKey, null);
});
test("4 parallel-race picks fastest local over slow cloud", async (t) => {
  const fast = await stub((_, r) => {
    r.writeHead(200, { "content-type": "application/json" });
    r.end(JSON.stringify({ answers: { route: { choice: "local_direct", confidence: 0.9 } } }));
  });
  const slow = await stub((_, r) => {
    setTimeout(() => { r.writeHead(200, { "content-type": "application/json" }); r.end(JSON.stringify({ answers: { route: { choice: "compact", confidence: 0.5 } } })); }, 400);
  });
  t.after(() => new Promise((r) => fast.server.close(() => r())));
  t.after(() => new Promise((r) => slow.server.close(() => r())));
  const out = await jevEvaluate({ document: "race" }, Q(), { localUrl: `http://127.0.0.1:${fast.port}`, cloudUrl: `http://127.0.0.1:${slow.port}`, apiKey: "k", mode: "parallel-race", timeoutMs: 2000 });
  assert.equal(out._source, "local");
  assert.equal(out.answers.route.choice, "local_direct");
});
test("5 routeLocalRequest parses thinking+route+risk from local", async (t) => {
  const { server, port } = await stub((_, r) => {
    r.writeHead(200, { "content-type": "application/json" });
    r.end(JSON.stringify({ answers: { needs_thinking: { noul: 0.12 }, route: { choice: "local_direct", confidence: 0.94 }, risk: { score: 0.1 } } }));
  });
  t.after(() => new Promise((r) => server.close(() => r())));
  const out = await routeLocalRequest("refund duplicate today or cancel", { localUrl: `http://127.0.0.1:${port}`, mode: "local-only", timeoutMs: 2000 });
  assert.equal(out.route, "local_direct");
  assert.equal(out.source, "local");
  assert.ok(out.needsThinking < 0.5);
  assert.ok(out.risk < 0.5);
});
test("6 guardrail danger score blocks risky shell", async (t) => {
  const { server, port } = await stub((_, r) => {
    r.writeHead(200, { "content-type": "application/json" });
    r.end(JSON.stringify({ answers: { needs_thinking: { noul: 0.9 }, route: { choice: "local_think", confidence: 0.8 }, risk: { score: 1.9 } } }));
  });
  t.after(() => new Promise((r) => server.close(() => r())));
  const out = await routeLocalRequest("rm -rf / --no-preserve-root", { localUrl: `http://127.0.0.1:${port}`, mode: "local-only", timeoutMs: 2000 });
  assert.ok(out.risk > 1.0);
  assert.equal(out.route, "local_think");
});
test("7 research rerank triple relevance+trust+depth via local", async (t) => {
  const { server, port } = await stub((_, r) => {
    r.writeHead(200, { "content-type": "application/json" });
    r.end(JSON.stringify({ answers: { relevance: { noul: 0.92 }, trust: { noul: 0.81 }, depth: { score: 2.4 } } }));
  });
  t.after(() => new Promise((r) => server.close(() => r())));
  const out = await jevEvaluate({ query: "qwen ctx", page: "262k tokens" }, { relevance: { type: "noul", instructions: "answer?" }, trust: { type: "noul", instructions: "trust?" }, depth: { type: "score", instructions: "depth?", criteria: ["a", "b"] } }, { localUrl: `http://127.0.0.1:${port}`, mode: "local-only", timeoutMs: 2000 });
  assert.ok(out.answers.relevance.noul > 0.9);
  assert.ok(out.answers.trust.noul > 0.5);
  assert.ok(out.answers.depth.score > 2.0);
});
test("8 compaction decision routes long ctx to compact", async (t) => {
  const { server, port } = await stub((_, r) => {
    r.writeHead(200, { "content-type": "application/json" });
    r.end(JSON.stringify({ answers: { needs_thinking: { noul: 0.4 }, route: { choice: "compact", confidence: 0.77 }, risk: { score: 0 } } }));
  });
  t.after(() => new Promise((r) => server.close(() => r())));
  const out = await routeLocalRequest("x".repeat(50000), { localUrl: `http://127.0.0.1:${port}`, mode: "local-only", timeoutMs: 2000 });
  assert.equal(out.route, "compact");
});
test("9 slow local times out then cloud answers", async (t) => {
  const slowLocal = await stub((_, r) => {
    setTimeout(() => { r.writeHead(200, { "content-type": "application/json" }); r.end(JSON.stringify({ answers: { route: { choice: "local_direct", confidence: 1 } } })); }, 600);
  });
  const cloud = await stub((_, r) => {
    r.writeHead(200, { "content-type": "application/json" });
    r.end(JSON.stringify({ answers: { route: { choice: "local_think", confidence: 0.7 } } }));
  });
  t.after(() => new Promise((r) => slowLocal.server.close(() => r())));
  t.after(() => new Promise((r) => cloud.server.close(() => r())));
  const out = await jevEvaluate({ document: "timeout" }, Q(), { localUrl: `http://127.0.0.1:${slowLocal.port}`, cloudUrl: `http://127.0.0.1:${cloud.port}`, apiKey: "k", mode: "local-first", timeoutMs: 80 });
  assert.equal(out._source, "cloud");
});
test("10 malformed local falls back, malformed both returns null", async (t) => {
  const bad = await stub((_, r) => { r.writeHead(200, { "content-type": "application/json" }); r.end("<<not json>>"); });
  const bad2 = await stub((_, r) => { r.writeHead(500); r.end("err"); });
  const good = await stub((_, r) => {
    r.writeHead(200, { "content-type": "application/json" });
    r.end(JSON.stringify({ answers: { route: { choice: "local_direct", confidence: 0.6 } } }));
  });
  t.after(() => new Promise((r) => bad.server.close(() => r())));
  t.after(() => new Promise((r) => bad2.server.close(() => r())));
  t.after(() => new Promise((r) => good.server.close(() => r())));
  const fallback = await jevEvaluate({ document: "x" }, Q(), { localUrl: `http://127.0.0.1:${bad.port}`, cloudUrl: `http://127.0.0.1:${good.port}`, apiKey: "k", mode: "local-first", timeoutMs: 1000 });
  assert.equal(fallback._source, "cloud");
  const nullOut = await jevEvaluate({ document: "x" }, Q(), { localUrl: `http://127.0.0.1:${bad2.port}`, mode: "local-only", timeoutMs: 1000 });
  assert.equal(nullOut, null);
});
