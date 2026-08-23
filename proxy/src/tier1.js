// Tier 1: tool-result elision; see docs/compaction-strategy.md.
//
// For every evictable message that carries a tool result, if the result body
// exceeds `min_tokens`, persist the original verbatim under
// `<cacheDir>/tool-results/<id>.json` and replace the inline content with a
// stub of the form documented in proxy/eval/README.md:
//
//   <tool_result id="t12" tool="Read" args={path:"foo.py"} bytes=14823
//    first_lines="def main():..." />
//
// We handle two shapes:
//   - OpenAI: { role: "tool", tool_call_id, name, content: "<text>" }
//   - Anthropic-style content blocks on a user/assistant message:
//       content: [{ type: "tool_result", tool_use_id, content: ... }, ...]
//
// We never reorder kept messages. We never touch verbatim messages.

import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const FIRST_LINES_MAX_LINES = 5;
const FIRST_LINES_MAX_CHARS = 200;

function stableId(seedParts) {
  const h = createHash("sha256");
  for (const p of seedParts) h.update(String(p ?? ""));
  return "t-" + h.digest("hex").slice(0, 12);
}

function jsonAttr(v) {
  // Compact JSON, then escape so it's safe inside a double-quoted XML attribute.
  const j = typeof v === "string" ? v : JSON.stringify(v ?? {});
  return j
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function firstLines(s) {
  if (typeof s !== "string") s = JSON.stringify(s ?? "");
  const head = s.split("\n").slice(0, FIRST_LINES_MAX_LINES).join("\n");
  const truncated = head.length > FIRST_LINES_MAX_CHARS
    ? head.slice(0, FIRST_LINES_MAX_CHARS) + "..."
    : head;
  // Encode for XML attribute. Keep newlines as literal \n so the model sees them.
  return truncated
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/\n/g, "\\n")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function contentToString(content) {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((p) => {
        if (typeof p === "string") return p;
        if (p && typeof p.text === "string") return p.text;
        if (p && typeof p.content === "string") return p.content;
        return JSON.stringify(p);
      })
      .join("\n");
  }
  if (content == null) return "";
  return JSON.stringify(content);
}

function buildStub({ id, tool, args, bytes, body }) {
  const argsAttr = jsonAttr(args ?? {});
  const fl = firstLines(body);
  const toolAttr = jsonAttr(tool || "unknown");
  return `<tool_result id="${id}" tool="${toolAttr}" args="${argsAttr}" bytes=${bytes} first_lines="${fl}" />`;
}

function persist(cacheDir, id, payload) {
  const dir = resolve(cacheDir, "tool-results");
  mkdirSync(dir, { recursive: true });
  writeFileSync(resolve(dir, `${id}.json`), JSON.stringify(payload, null, 2));
}

// Synchronous tokenizer interface: caller pre-resolves a counts map keyed by
// the exact body string. We keep tier1 sync to make the rewrite deterministic
// and easy to test; the server pre-tokenizes any candidate bodies.
//
// Options:
//   minTokens: int (default 2000)
//   cacheDir: absolute path
//   tokenCount: (text) => int   — sync, REQUIRED for any candidate
//   persistFn: (id, payload) => void  — override for tests
//   toolNameFromCallId: Map<string,string>  — to recover `tool` for results that
//                                              only carry tool_call_id
export function applyTier1({
  messages,
  evictableIndices,
  opts,
}) {
  const minTokens = opts.minTokens ?? 2000;
  const cacheDir = opts.cacheDir;
  const tokenCount = opts.tokenCount;
  const persistFn = opts.persistFn || ((id, p) => persist(cacheDir, id, p));
  const toolNameFromCallId = opts.toolNameFromCallId || new Map();

  if (typeof tokenCount !== "function") {
    throw new Error("applyTier1: opts.tokenCount(text) is required");
  }

  const out = messages.map((m) => m); // shallow clone array; we replace entries
  const elidedIds = [];
  let tokensSavedEstimate = 0;

  const evictableSet = new Set(evictableIndices);

  for (const i of evictableIndices) {
    const m = messages[i];
    if (!m) continue;

    // Shape A: OpenAI role:"tool".
    if (m.role === "tool") {
      const body = contentToString(m.content);
      const n = tokenCount(body);
      if (n < minTokens) continue;
      const tool =
        m.name || toolNameFromCallId.get(m.tool_call_id) || "unknown";
      const id = m.tool_call_id || stableId([m.role, tool, body]);
      const stub = buildStub({
        id,
        tool,
        args: {},
        bytes: Buffer.byteLength(body, "utf8"),
        body,
      });
      persistFn(id, {
        id,
        role: "tool",
        tool_call_id: m.tool_call_id ?? null,
        name: tool,
        content: m.content,
      });
      out[i] = { ...m, content: stub };
      elidedIds.push(id);
      tokensSavedEstimate += Math.max(0, n - tokenCount(stub));
      continue;
    }

    // Shape B: content is an array with type:"tool_result" parts.
    if (Array.isArray(m.content)) {
      let mutated = false;
      const newParts = m.content.map((part) => {
        if (!part || part.type !== "tool_result") return part;
        const body = contentToString(part.content);
        const n = tokenCount(body);
        if (n < minTokens) return part;
        const callId = part.tool_use_id || part.tool_call_id;
        const tool = toolNameFromCallId.get(callId) || part.name || "unknown";
        const id = callId || stableId([m.role, tool, body]);
        const stub = buildStub({
          id,
          tool,
          args: {},
          bytes: Buffer.byteLength(body, "utf8"),
          body,
        });
        persistFn(id, {
          id,
          role: m.role,
          tool_use_id: callId ?? null,
          name: tool,
          content: part.content,
        });
        elidedIds.push(id);
        tokensSavedEstimate += Math.max(0, n - tokenCount(stub));
        mutated = true;
        return { ...part, content: stub };
      });
      if (mutated) {
        out[i] = { ...m, content: newParts };
      }
      continue;
    }
  }

  return {
    rewrittenMessages: out,
    elidedIds,
    tokensSavedEstimate,
  };
}

// Build a Map<tool_call_id, tool_name> by scanning assistant messages' tool_calls.
// This lets us recover a meaningful `tool` attribute on the stub even if the
// upstream `tool` message only carries the id.
export function buildToolNameIndex(messages) {
  const idx = new Map();
  for (const m of messages || []) {
    if (Array.isArray(m?.tool_calls)) {
      for (const tc of m.tool_calls) {
        const id = tc?.id;
        const name = tc?.function?.name;
        if (id && name) idx.set(id, name);
      }
    }
  }
  return idx;
}

export const TIER1_DEFAULTS = {
  minTokens: 2000,
};

// Safe serialization of `elidedIds` for HTTP response headers.
// Most servers (and proxies in front of them) cap a single response header at
// ~8-16KB. With long tool_call_ids this list can blow that budget. Callers
// should use this helper instead of stuffing the raw array into a header.
//
// Returns { ids, total_count, truncated } where `ids` is at most `maxIds` long
// and the JSON encoding is bounded by `maxBytes` (default 4096, well under
// typical 8KB header limits even after the surrounding `x-rewrite-stats` JSON).
export function summarizeElidedIds(ids, opts = {}) {
  const maxIds = opts.maxIds ?? 64;
  const maxBytes = opts.maxBytes ?? 4096;
  const arr = Array.isArray(ids) ? ids : [];
  const total = arr.length;
  let kept = arr.slice(0, maxIds);
  // Tighten further if the JSON-encoded form would still bust maxBytes.
  while (kept.length > 0 && Buffer.byteLength(JSON.stringify(kept), "utf8") > maxBytes) {
    kept = kept.slice(0, Math.max(1, Math.floor(kept.length / 2)));
  }
  return {
    ids: kept,
    total_count: total,
    truncated: kept.length < total,
  };
}

// Phantom tool definition the model can call to rehydrate elided results.
export const EXPAND_TOOL_DEFINITION = {
  type: "function",
  function: {
    name: "expand_tool_result",
    description:
      "Rehydrate a previously elided tool result. Pass the id from the <tool_result id=\"...\"/> stub. The proxy answers locally; this call never reaches the model.",
    parameters: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "The id from the elided <tool_result/> stub.",
        },
      },
      required: ["id"],
      additionalProperties: false,
    },
  },
};
