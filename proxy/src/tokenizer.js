// Tokenizer client. Calls upstream /tokenize (llama-server) and caches by exact
// string. Token counts here MUST come from the same tokenizer the primary model
// uses, so we never use tiktoken or a JS fallback.
import { LRU } from "./lru.js";

export class TokenizerClient {
  constructor({ baseUrl, cacheEntries = 4096, logger }) {
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.cache = new LRU(cacheEntries);
    this.logger = logger;
  }

  async countTokens(text) {
    if (!text) return 0;
    const cached = this.cache.get(text);
    if (cached !== undefined) return cached;

    const res = await fetch(`${this.baseUrl}/tokenize`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ content: text }),
    });
    if (!res.ok) {
      throw new Error(`tokenize failed: ${res.status} ${res.statusText}`);
    }
    const body = await res.json();
    // llama-server returns {tokens: [...]}
    const n = Array.isArray(body.tokens) ? body.tokens.length : 0;
    this.cache.set(text, n);
    return n;
  }

  // Approximate count over an OpenAI-style messages array. Phase 0 instrumentation
  // only — does not include chat-template overhead. Phase 1 will switch to a
  // /tokenize call against the rendered template once we wire that in.
  async countMessages(messages) {
    if (!Array.isArray(messages)) return 0;
    let total = 0;
    for (const m of messages) {
      if (!m) continue;
      if (typeof m.content === "string") {
        total += await this.countTokens(m.content);
      } else if (Array.isArray(m.content)) {
        for (const part of m.content) {
          if (part && typeof part.text === "string") {
            total += await this.countTokens(part.text);
          }
        }
      }
      if (Array.isArray(m.tool_calls)) {
        for (const tc of m.tool_calls) {
          const args = tc?.function?.arguments;
          if (typeof args === "string") total += await this.countTokens(args);
        }
      }
    }
    return total;
  }
}
