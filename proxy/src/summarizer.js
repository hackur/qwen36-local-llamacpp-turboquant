// Phase 2 same-model summarizer; see docs/compaction-strategy.md.
//
// Posts directly to the Qwen3.8 upstream before forwarding the rewritten request
// at /v1/chat/completions and returns a single condensed text block. Used by the
// rewrite pipeline to compress oversized tool-result bodies before Tier 1 falls
// through to stub-only elision.
//
// Hard rule: this client must NEVER fail a request. Any error (offline, bad
// JSON, timeout, non-2xx) returns null — caller falls through to existing
// behavior (Tier 1 stubbing).
//
// Caller contract:
//   summarize(messages, { url, timeoutMs, model, logger }) -> Promise<string|null>

const DEFAULT_TIMEOUT_MS = 8000;
const DEFAULT_MAX_TOKENS = 512;

const SYSTEM_PROMPT =
  "You are a compression engine. Given a tool-result payload, produce a tight " +
  "decision-log style summary preserving identifiers, paths, errors, exit codes, " +
  "and numeric facts verbatim. Drop boilerplate. Keep names exact. Output ONLY " +
  "the summary; no preface, no markdown fences.";

// POST a /v1/chat/completions request to the summarizer and return the
// assistant text on success, or null on any failure.
//
// `messages` is the chat array forwarded to the small model. Typically the
// caller wraps a single user message containing the oversized tool-result body
// and the framing instructions.
export async function summarize(messages, opts = {}) {
  const url = opts.url;
  if (!url) return null;
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const logger = opts.logger;

  const payload = {
    model: opts.model || "qwen3.8-local",
    messages,
    max_tokens: opts.maxTokens ?? DEFAULT_MAX_TOKENS,
    temperature: 0,
    stream: false,
  };

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const endpoint = url.replace(/\/+$/, "") + "/v1/chat/completions";
    const res = await fetch(endpoint, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
    if (!res.ok) {
      logger?.warn?.(
        { status: res.status },
        "summarizer non-2xx; bypassing",
      );
      return null;
    }
    const text = await res.text();
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch (err) {
      logger?.warn?.(
        { err: err.message },
        "summarizer returned invalid JSON; bypassing",
      );
      return null;
    }
    const content = parsed?.choices?.[0]?.message?.content;
    if (typeof content !== "string" || content.length === 0) return null;
    return content;
  } catch (err) {
    if (err?.name === "AbortError") {
      logger?.warn?.({ timeoutMs }, "summarizer timed out; bypassing");
    } else {
      logger?.warn?.(
        { err: err.message },
        "summarizer call failed; bypassing",
      );
    }
    return null;
  } finally {
    clearTimeout(timer);
  }
}

// Helper: build the messages array that summarize() expects from a single
// oversized tool-result body. Centralised here so tests + rewrite agree.
export function buildToolResultPrompt({ tool, body }) {
  const head =
    `Tool: ${tool || "unknown"}\n` +
    `Compress the following tool result. Keep identifiers, paths, error text, ` +
    `exit codes, and numeric facts verbatim.\n\n---\n${body}\n---`;
  return [
    { role: "system", content: SYSTEM_PROMPT },
    { role: "user", content: head },
  ];
}
