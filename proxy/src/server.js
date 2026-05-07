// HTTP server. Phase 0: pure passthrough with instrumentation.
//
// Design notes:
// - We do NOT use the streams web API for the upstream body — Node's
//   `fetch().body` is a web ReadableStream, but we want byte-for-byte
//   forwarding with no buffering and no transcoding, so we read it via the
//   async iterator and write straight to the client response. Each chunk is
//   a Uint8Array; we forward unchanged.
// - For non-streaming responses we still use the same path; the bytes happen
//   to arrive as one chunk and go out as one chunk.
// - SSE framing (`data: ...\n\n`, including the terminal `data: [DONE]\n\n`)
//   is a property of the upstream payload — we never parse or rewrite it.
// - We capture token usage opportunistically by sniffing the final
//   non-streaming JSON response or the last streaming chunk that contains a
//   `usage` field (llama-server emits one when stream_options.include_usage).
//   If we can't see it, completion_tokens is logged as null. That's fine for
//   Phase 0 instrumentation.
import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { rewriteRequest, answerExpandCalls } from "./rewrite.js";

// Inline-header budget for x-rewritten-messages. Header size is the
// load-bearing constraint here; HTTP servers commonly accept ~8KB per header
// line. Keep margin so combined response headers don't exceed the limit.
const INLINE_HEADER_BUDGET = 6 * 1024;

const HOP_BY_HOP = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailers",
  "transfer-encoding",
  "upgrade",
  "host",
  "content-length",
]);

function copyHeaders(src) {
  const out = {};
  for (const [k, v] of Object.entries(src)) {
    if (HOP_BY_HOP.has(k.toLowerCase())) continue;
    out[k] = v;
  }
  return out;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

// Look for {"usage":{"prompt_tokens":X,"completion_tokens":Y,...}} in a buffer.
// llama-server emits a nested object (`prompt_tokens_details:{cached_tokens:N}`),
// so we walk braces with a depth counter rather than using a flat regex —
// otherwise the match stops at the first inner `}` and JSON.parse fails.
// Skips over braces inside strings (incl. escaped quotes) so embedded JSON
// strings don't confuse the depth counter.
export function sniffUsage(text) {
  const key = '"usage"';
  let i = text.lastIndexOf(key);
  while (i !== -1) {
    let j = i + key.length;
    while (j < text.length && /\s/.test(text[j])) j++;
    if (text[j] !== ":") {
      i = text.lastIndexOf(key, i - 1);
      continue;
    }
    j++;
    while (j < text.length && /\s/.test(text[j])) j++;
    if (text[j] !== "{") {
      i = text.lastIndexOf(key, i - 1);
      continue;
    }
    let depth = 0;
    let inStr = false;
    let esc = false;
    for (let k = j; k < text.length; k++) {
      const ch = text[k];
      if (esc) { esc = false; continue; }
      if (ch === "\\") { esc = true; continue; }
      if (ch === '"') { inStr = !inStr; continue; }
      if (inStr) continue;
      if (ch === "{") depth++;
      else if (ch === "}") {
        depth--;
        if (depth === 0) {
          try {
            return JSON.parse(text.slice(j, k + 1));
          } catch {
            return null;
          }
        }
      }
    }
    return null;
  }
  return null;
}

export function createProxyServer({
  config,
  upstream,
  tokenizer,
  jsonl,
  logger,
}) {
  const upstreamUrl = config.upstream.base_url.replace(/\/+$/, "");

  async function handleChat(req, res, requestId) {
    const start = Date.now();
    const body = await readBody(req);

    // Best-effort parse for instrumentation. If it isn't JSON, we still
    // forward the raw bytes — the upstream will error and the client sees the
    // same error it would have seen talking to llama-server directly.
    let parsed = null;
    try {
      parsed = JSON.parse(body.toString("utf8"));
    } catch {
      /* forward as-is */
    }

    const compactHeader = String(req.headers["x-compact"] || "").toLowerCase();
    const compactOff = compactHeader === "off";
    const isStreaming = parsed?.stream === true;
    const model = parsed?.model || null;
    const messageCount = Array.isArray(parsed?.messages)
      ? parsed.messages.length
      : null;

    let promptTokens = null;
    if (parsed?.messages) {
      try {
        promptTokens = await tokenizer.countMessages(parsed.messages);
      } catch (err) {
        logger.warn(
          { err: err.message, requestId },
          "tokenize failed; logging null prompt_tokens",
        );
      }
    }

    // Phantom expand_tool_result interception: any assistant tool_calls naming
    // expand_tool_result that are not yet answered get answered locally before
    // we even consider rewriting or forwarding. Modifies `parsed.messages` in
    // place. The proxy answers the call from the on-disk verbatim cache; the
    // model never sees that expand_tool_result is a phantom.
    let phantomAnswered = [];
    if (parsed?.messages && !compactOff) {
      try {
        const r = answerExpandCalls({
          messages: parsed.messages,
          cacheDir: config.cache_dir,
        });
        if (r.answered.length > 0) {
          parsed.messages = r.messages;
          phantomAnswered = r.answered;
        }
      } catch (err) {
        logger.warn(
          { err: err.message, requestId },
          "expand_tool_result interception failed; continuing",
        );
      }
    }

    // Rewrite pipeline (Tier 0 + Tier 1). Always run when not opted-out, so
    // that x-debug-rewritten and shadow-mode logging both work regardless of
    // mode. Wrap in try/catch — compaction must never crash a request.
    const debugRewrite = String(req.headers["x-debug-rewritten"] || "") === "1";
    let rewrite = null;
    if (!compactOff && parsed?.messages) {
      try {
        rewrite = await rewriteRequest({
          body: parsed,
          tokenizer,
          config,
          cacheDir: config.cache_dir,
          nCtx: upstream?.nCtx || 0,
          logger,
        });
      } catch (err) {
        logger.warn(
          { err: err.message, requestId },
          "rewrite pipeline failed; falling through to passthrough",
        );
        rewrite = null;
      }
    }

    // Debug-rewrite contract (proxy/eval/README.md): short-circuit BEFORE any
    // upstream call. Independent of mode. Always 200 with empty body.
    if (debugRewrite && rewrite) {
      const headers = { "content-type": "application/json" };
      headers["x-proxy-request-id"] = requestId;
      headers["x-rewrite-stats"] = JSON.stringify(rewrite.stats);
      const messagesJson = JSON.stringify(rewrite.rewrittenBody.messages);
      if (messagesJson.length <= INLINE_HEADER_BUDGET) {
        headers["x-rewritten-messages"] = messagesJson;
      } else {
        const debugDir = resolve(config.cache_dir, "debug");
        mkdirSync(debugDir, { recursive: true });
        const sidecar = resolve(debugDir, `${requestId}.json`);
        writeFileSync(
          sidecar,
          JSON.stringify(rewrite.rewrittenBody.messages, null, 2),
        );
        headers["x-rewritten-sidecar"] = sidecar;
      }
      res.writeHead(200, headers);
      res.end("{}");
      jsonl.write({
        request_id: requestId,
        model,
        mode: config.mode,
        compact: compactOff ? "off" : "on",
        debug_rewrite: true,
        message_count: messageCount,
        prompt_tokens: rewrite.stats.orig_tokens,
        rewritten_tokens: rewrite.stats.rewritten_tokens,
        elided_ids: rewrite.stats.elided_tool_result_ids,
        phantom_answered: phantomAnswered,
        latency_ms: Date.now() - start,
      });
      return;
    }

    // Decide what body to forward based on mode.
    //   passthrough — never rewrite, never compact (parsed may still have had
    //     phantom expand_tool_result answered; we forward that change).
    //   shadow      — compute the rewrite, log it, forward ORIGINAL.
    //   enforce     — compute the rewrite, forward REWRITTEN.
    let outboundBuf = body;
    if (parsed) {
      if (config.mode === "enforce" && rewrite) {
        outboundBuf = Buffer.from(JSON.stringify(rewrite.rewrittenBody), "utf8");
      } else if (phantomAnswered.length > 0) {
        // Phantom answers belong on the wire even in passthrough/shadow.
        outboundBuf = Buffer.from(JSON.stringify(parsed), "utf8");
      }
    }

    if (config.mode === "shadow" && rewrite) {
      logger.info(
        {
          requestId,
          orig_tokens: rewrite.stats.orig_tokens,
          rewritten_tokens: rewrite.stats.rewritten_tokens,
          elided_ids: rewrite.stats.elided_tool_result_ids,
        },
        "shadow rewrite (not forwarded)",
      );
    }

    const upstreamHeaders = copyHeaders(req.headers);
    upstreamHeaders["content-type"] =
      upstreamHeaders["content-type"] || "application/json";

    let upstreamRes;
    try {
      upstreamRes = await fetch(`${upstreamUrl}/v1/chat/completions`, {
        method: "POST",
        headers: upstreamHeaders,
        body: outboundBuf,
      });
    } catch (err) {
      logger.error(
        { err: err.message, requestId },
        "upstream connection failed",
      );
      res.writeHead(502, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: { message: err.message } }));
      return;
    }

    // Mirror status + headers, drop hop-by-hop, inject our request id.
    const respHeaders = {};
    upstreamRes.headers.forEach((v, k) => {
      if (!HOP_BY_HOP.has(k.toLowerCase())) respHeaders[k] = v;
    });
    respHeaders["x-proxy-request-id"] = requestId;
    if (compactOff) respHeaders["x-compact"] = "off";
    res.writeHead(upstreamRes.status, respHeaders);

    let completionTokens = null;
    let sniffBuf = "";
    const SNIFF_MAX = 64 * 1024;

    try {
      for await (const chunk of upstreamRes.body) {
        // chunk is Uint8Array. Write through unchanged.
        res.write(chunk);
        if (sniffBuf.length < SNIFF_MAX) {
          sniffBuf += Buffer.from(chunk).toString("utf8");
          if (sniffBuf.length > SNIFF_MAX) {
            sniffBuf = sniffBuf.slice(-SNIFF_MAX);
          }
        }
      }
    } catch (err) {
      logger.warn(
        { err: err.message, requestId },
        "upstream stream interrupted",
      );
    }
    res.end();

    const usage = sniffUsage(sniffBuf);
    if (usage) {
      completionTokens = usage.completion_tokens ?? null;
      // Trust upstream's prompt_tokens over our local count when present.
      if (typeof usage.prompt_tokens === "number") {
        promptTokens = usage.prompt_tokens;
      }
    }

    const record = {
      request_id: requestId,
      model,
      mode: config.mode,
      compact: compactOff ? "off" : "on",
      stream: isStreaming,
      message_count: messageCount,
      prompt_tokens: promptTokens,
      completion_tokens: completionTokens,
      status: upstreamRes.status,
      latency_ms: Date.now() - start,
      rewrite: rewrite
        ? {
            orig_tokens: rewrite.stats.orig_tokens,
            rewritten_tokens: rewrite.stats.rewritten_tokens,
            elided_ids: rewrite.stats.elided_tool_result_ids,
          }
        : null,
      phantom_answered: phantomAnswered,
    };
    jsonl.write(record);
    logger.debug(record, "request complete");
  }

  async function handlePassthrough(req, res, requestId) {
    const start = Date.now();
    const url = `${upstreamUrl}${req.url}`;
    let body;
    if (req.method !== "GET" && req.method !== "HEAD") {
      body = await readBody(req);
    }
    const headers = copyHeaders(req.headers);
    let upstreamRes;
    try {
      upstreamRes = await fetch(url, { method: req.method, headers, body });
    } catch (err) {
      res.writeHead(502, { "content-type": "application/json" });
      res.end(JSON.stringify({ error: { message: err.message } }));
      return;
    }
    const respHeaders = {};
    upstreamRes.headers.forEach((v, k) => {
      if (!HOP_BY_HOP.has(k.toLowerCase())) respHeaders[k] = v;
    });
    respHeaders["x-proxy-request-id"] = requestId;
    res.writeHead(upstreamRes.status, respHeaders);
    if (upstreamRes.body) {
      for await (const chunk of upstreamRes.body) res.write(chunk);
    }
    res.end();
    logger.debug(
      { requestId, path: req.url, status: upstreamRes.status, latency_ms: Date.now() - start },
      "passthrough complete",
    );
  }

  function handleProxyInfo(req, res) {
    const payload = {
      version: "0.1.0",
      mode: config.mode,
      upstream: config.upstream.base_url,
      n_ctx: upstream.nCtx,
      cache_dir: config.cache_dir,
      tokenizer_cache: tokenizer.cache.size,
      watermarks: config.watermarks,
    };
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify(payload, null, 2));
  }

  const server = createServer((req, res) => {
    const requestId = randomUUID();
    res.on("close", () => {
      // nothing to clean up; here for future hooks
    });

    const url = req.url || "/";

    if (req.method === "POST" && url === "/v1/chat/completions") {
      handleChat(req, res, requestId).catch((err) => {
        logger.error({ err: err.message, requestId }, "chat handler crashed");
        if (!res.headersSent) {
          res.writeHead(500, { "content-type": "application/json" });
          res.end(JSON.stringify({ error: { message: err.message } }));
        } else {
          res.end();
        }
      });
      return;
    }

    if (url === "/proxy/info") {
      handleProxyInfo(req, res);
      return;
    }

    // Pass through anything else llama-server serves: /v1/models, /health,
    // /v1/completions, /tokenize, /props, /slots/*, etc.
    handlePassthrough(req, res, requestId).catch((err) => {
      logger.error({ err: err.message, requestId }, "passthrough crashed");
      if (!res.headersSent) {
        res.writeHead(500, { "content-type": "application/json" });
        res.end(JSON.stringify({ error: { message: err.message } }));
      } else {
        res.end();
      }
    });
  });

  return server;
}
