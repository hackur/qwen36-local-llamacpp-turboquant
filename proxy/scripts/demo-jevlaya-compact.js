#!/usr/bin/env node
// ============================================================================
// DEMO: Frequent compaction with stub Jev-compatible local/cloud servers.
// ============================================================================
//
// WHAT THIS SHOWS:
//   1. A tiny local "Laya-like" decision server answers in ~20ms with typed
//      answers: { route: choice, needs_thinking: noul, risk: score }.
//   2. jevEvaluate() tries local first, falls back to cloud, or races both.
//   3. routeLocalRequest() parses that into { route, needsThinking, risk }.
//   4. rewriteRequest() uses those signals PLUS watermarks to compact MORE
//      OFTEN: big tool results get elided to re-hydratable stubs, so every
//      upstream request is smaller = faster prefill + long agents survive.
//
// This is a deterministic illustration with fake classifier replies and a
// chars/4 tokenizer. Token savings and 30-turn numbers are estimates, not a
// measured latency, KV-cache, or live Laya result.
//
// RUN:  node proxy/scripts/demo-jevlaya-compact.js
// ============================================================================

import { createServer } from "node:http";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { jevEvaluate, routeLocalRequest } from "../src/jev.js";
import { rewriteRequest } from "../src/rewrite.js";
import { LRU } from "../src/lru.js";

// ----------------------------------------------------------------------------
// Helper 1: Fake tokenizer (deterministic, no server needed).
// Real proxy uses TokenizerClient -> llama-server /tokenize. Here 1 token per
// 4 chars so the demo runs anywhere. Shape matches what rewrite.js expects:
//   { cache: LRU, countTokens(text): Promise<number> }
// ----------------------------------------------------------------------------
function makeDemoTokenizer() {
  const cache = new LRU(4096);
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

// ----------------------------------------------------------------------------
// Helper 2: Start a stub Jev-compatible server on an ephemeral port.
// Responds to POST /v1/systemone with whatever JSON your handler returns.
// Returns { server, port, url }. Caller must close server when done.
// ----------------------------------------------------------------------------
function startStubJev(handler, delayMs = 0) {
  return new Promise((res) => {
    const server = createServer((req, response) => {
      // Only the Jev endpoint matters; everything else 404s.
      if (req.url === "/v1/systemone" && req.method === "POST") {
        let body = "";
        req.on("data", (c) => (body += c));
        req.on("end", () => {
          // Parse incoming { state, questions } so stubs can route on content.
          let parsed = {};
          try { parsed = JSON.parse(body); } catch { parsed = {}; }
          const reply = () => handler(parsed, response);
          if (delayMs > 0) setTimeout(reply, delayMs);
          else reply();
        });
        return;
      }
      response.writeHead(404);
      response.end();
    });
    // Port 0 = OS picks a free port. Bind loopback only (never expose).
    server.listen(0, "127.0.0.1", () => {
      const port = server.address().port;
      res({ server, port, url: `http://127.0.0.1:${port}` });
    });
  });
}

// ----------------------------------------------------------------------------
// Helper 3: Build a fake long-running agent history.
// 1 system prompt + N turns of (user -> assistant tool_call -> big tool result).
// Each tool result is `toolChars` of filler, simulating Read/Grep outputs.
// ----------------------------------------------------------------------------
function buildLongHistory({ turns = 12, toolChars = 6000 }) {
  const messages = [{ role: "system", content: "You are a coding agent. Be concise." }];
  for (let i = 0; i < turns; i++) {
    messages.push({ role: "user", content: `Step ${i + 1}: check module ${i} and fix tests` });
    messages.push({
      role: "assistant", content: null,
      tool_calls: [{ id: `call_${i}`, type: "function", function: { name: "Read", arguments: `{"path":"src/mod${i}.js"}` } }],
    });
    messages.push({
      role: "tool", tool_call_id: `call_${i}`, name: "Read",
      // Big filler body: this is what compaction will elide.
      content: `FILE src/mod${i}.js (${toolChars} chars)\n` + "x".repeat(toolChars),
    });
  }
  messages.push({ role: "user", content: "Summarize what changed and what is next" });
  return messages;
}

// ----------------------------------------------------------------------------
// MAIN DEMO - runs top to bottom, prints each stage so you can follow along.
// ----------------------------------------------------------------------------
async function main() {
  console.log("=== Demo: frequent compaction with parallel Jev plane ===\n");

  // -- Stage 1: boot a fast local stub (acts like laya-serve on :8000) ------
  // It reads the state text and returns:
  //   route=compact when state is huge, else local_direct.
  const smartLocal = await startStubJev((parsed, response) => {
    const stateText = JSON.stringify(parsed?.state ?? "");
    const isHuge = stateText.length > 20000;
    const looksShell = /rm -rf|chmod 777|>:?\s*\/dev\//.test(stateText);
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({
      answers: {
        needs_thinking: { noul: isHuge ? 0.4 : 0.15 },
        route: isHuge
          ? { choice: "compact", confidence: 0.82 }
          : { choice: "local_direct", confidence: 0.94 },
        risk: { score: looksShell ? 1.9 : 0.1 },
      },
    }));
  }, 15);

  // -- Stage 2: boot a slow cloud stub (acts like api.typesafe.ai) ----------
  // 250ms delay simulates network + big-model latency.
  const cloud = await startStubJev((_, response) => {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({
      answers: {
        needs_thinking: { noul: 0.5 },
        route: { choice: "local_think", confidence: 0.7 },
        risk: { score: 0.2 },
      },
    }));
  }, 250);

  console.log(`local stub: ${smartLocal.url} (~15ms, like laya-serve)`);
  console.log(`cloud stub: ${cloud.url} (~250ms, like TypeSafe API)\n`);

  const Q = {
    route: { type: "choice", instructions: "Pick handler", criteria: { local_direct: "lookup", local_think: "reason", compact: "summarize" } },
  };

  // -- Stage 3: local-first is fast and never touches cloud -----------------
  // Expected: _source=local, ~15ms. This is the hot path for every turn.
  let t0 = Date.now();
  const fast = await jevEvaluate(
    { document: "Duplicate charge on invoice #4411, refund duplicate" },
    Q,
    { localUrl: smartLocal.url, mode: "local-first", timeoutMs: 1500 },
  );
  console.log(`[3] local-first: source=${fast._source} route=${fast.answers.route.choice} took=${Date.now() - t0}ms`);

  // -- Stage 4: local offline -> automatic cloud fallback (fail-safe) -------
  // Point localUrl at a dead port; cloud stub still answers. Proxy never hard-fails.
  const fellBack = await jevEvaluate(
    { document: "arch debug multi-step" },
    Q,
    { localUrl: "http://127.0.0.1:1", cloudUrl: cloud.url, apiKey: "demo", mode: "local-first", timeoutMs: 1000 },
  );
  console.log(`[4] local dead -> fallback: source=${fellBack._source} route=${fellBack.answers.route.choice}`);

  // -- Stage 5: parallel-race takes the winner (local beats slow cloud) ----
  t0 = Date.now();
  const raced = await jevEvaluate(
    { document: "race me" }, Q,
    { localUrl: smartLocal.url, cloudUrl: cloud.url, apiKey: "demo", mode: "parallel-race", timeoutMs: 1500 },
  );
  console.log(`[5] parallel-race: source=${raced._source} route=${raced.answers.route.choice} took=${Date.now() - t0}ms`);

  // -- Stage 6: typed parse for proxy logic (thinking/route/risk) -----------
  const routed = await routeLocalRequest("refund duplicate today or cancel", { localUrl: smartLocal.url, mode: "local-only", timeoutMs: 1500 });
  console.log(`[6] routeLocalRequest: route=${routed.route} conf=${routed.routeConfidence} thinking=${routed.needsThinking} risk=${routed.risk} source=${routed.source}`);

  // -- Stage 7: conservative vs frequent compaction on a long history -------
  // Same 12-turn history (~20k tokens). Conservative rarely fires; frequent
  // elides every big tool result to a stub the model can expand on demand.
  const tokenizer = makeDemoTokenizer();
  const cacheDir = mkdtempSync(resolve(tmpdir(), "jev-demo-"));
  const messages = buildLongHistory({ turns: 12, toolChars: 6000 });
  const body = { model: "qwen3.8-local", messages };

  // Conservative = today's defaults: high thresholds, rarely compacts.
  const conservative = await rewriteRequest({
    body: structuredClone(body), tokenizer, cacheDir, nCtx: 262144,
    config: { watermarks: { prompt_fraction: 0.7, tool_result_min_tokens: 2000, max_messages: 40, max_age_turns: 20, verbatim_keep_turns: 8, verbatim_keep_tokens: 8000 } },
  });

  // Frequent = compact early and often: low thresholds + small verbatim tail.
  const frequent = await rewriteRequest({
    body: structuredClone(body), tokenizer, cacheDir, nCtx: 262144,
    config: { watermarks: { prompt_fraction: 0.15, tool_result_min_tokens: 500, max_messages: 8, max_age_turns: 4, verbatim_keep_turns: 2, verbatim_keep_tokens: 2000 } },
  });

  console.log(`\n[7] conservative: orig=${conservative.stats.orig_tokens} rewritten=${conservative.stats.rewritten_tokens} elided=${conservative.stats.elided_tool_result_ids.length}`);
  console.log(`[7] frequent:     orig=${frequent.stats.orig_tokens} rewritten=${frequent.stats.rewritten_tokens} elided=${frequent.stats.elided_tool_result_ids.length}`);
  const saved = conservative.stats.orig_tokens - frequent.stats.rewritten_tokens;
  const pct = Math.round((saved / conservative.stats.orig_tokens) * 100);
  console.log(`[7] frequent saves ~${saved} tokens (~${pct}% smaller prompt -> faster prefill, higher KV reuse)`);

  // Show what a stub looks like (first elided tool result, truncated).
  const stubMsg = frequent.rewrittenBody.messages.find((m) => typeof m.content === "string" && m.content.includes("expand_tool_result"));
  if (stubMsg) console.log(`[7] stub preview: ${String(stubMsg.content).slice(0, 160)}...`);

  // -- Stage 8: long-agent loop stays flat ----------------------------------
  // Simulate 30 turns: without compaction tokens grow linearly; with frequent
  // compaction each turn is rewritten to a bounded size. Numbers are estimates
  // from the 12-turn measurement above (per-turn cost after compaction).
  const perTurnOrig = Math.round(conservative.stats.orig_tokens / 12);
  const perTurnCompact = Math.round(frequent.stats.rewritten_tokens / 12);
  console.log(`\n[8] 30-turn projection: no-compact ~${perTurnOrig * 30} tokens (dies at 262k ctx) vs frequent ~${perTurnCompact * 30} tokens (keeps going)`);

  smartLocal.server.close();
  cloud.server.close();
  console.log("\nDone. Set jev.local_url=http://127.0.0.1:8000 mode=enforce for this behavior live.");
}

main().catch((e) => { console.error("demo failed:", e); process.exit(1); });
