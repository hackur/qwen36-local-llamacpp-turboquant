// watermark.js — compaction trigger logic.
//
// Implements the three context-pressure signals documented in
// docs/compaction-strategy.md:
//   1. Token watermark: currentTokens / nCtx >= watermarkRatio
//   2. Message-count + age: messages.length >= maxMessages AND oldest
//      non-system message is more than maxAge turns ago
//   3. Tool-result threshold: any single tool result over minTokens is
//      always elided (independent of 1/2)
//
// Pure module — no fs, no network. Tokenizer is injected by the caller.

/**
 * Default watermark configuration. These defaults are conservative and
 * documented in §5 of the compaction strategy. Tune in production.
 */
export const defaultWatermarkConfig = Object.freeze({
  // Compact when (currentTokens / nCtx) >= this. §5: 70% — fires before
  // context rot bites and before llama-server has to evict cache-reuse
  // prefix. Compresr defaults to 85%; we are stricter.
  watermarkRatio: 0.70,

  // Compact when messages.length >= this AND oldest non-system message is
  // more than maxAge turns ago. §5: 40 messages.
  maxMessages: 40,

  // Companion to maxMessages: oldest non-system message must be older than
  // this many turns from the tail. §5: 20 turns.
  maxAge: 20,

  // Tool-result elision threshold (Tier 1, always-on). §5/§6: 2000 tokens
  // matches the LangChain Deep Agents recommendation.
  toolResultMinTokens: 2000,
});

/**
 * Decide whether to run compaction on this request.
 *
 * @param {Array<{role: string, content?: any, tool_call_id?: string}>} messages
 *        OpenAI-style chat messages.
 * @param {Object} ctx
 * @param {number} ctx.nCtx              Slot context size in tokens.
 * @param {number} ctx.currentTokens     Tokenized size of the request.
 * @param {number} [ctx.watermarkRatio]  Override default 0.70.
 * @param {number} [ctx.maxMessages]     Override default 40.
 * @param {number} [ctx.maxAge]          Override default 20.
 * @returns {{compact: boolean, reason: string, signals: object}}
 */
export function shouldCompact(messages, ctx) {
  const cfg = {
    watermarkRatio: ctx?.watermarkRatio ?? defaultWatermarkConfig.watermarkRatio,
    maxMessages: ctx?.maxMessages ?? defaultWatermarkConfig.maxMessages,
    maxAge: ctx?.maxAge ?? defaultWatermarkConfig.maxAge,
  };
  const nCtx = Number(ctx?.nCtx) || 0;
  const currentTokens = Number(ctx?.currentTokens) || 0;
  const list = Array.isArray(messages) ? messages : [];

  // Signal 1: token watermark.
  const ratio = nCtx > 0 ? currentTokens / nCtx : 0;
  const tokenWatermarkHit = nCtx > 0 && ratio >= cfg.watermarkRatio;

  // Signal 2: message count + age. "Oldest non-system message more than
  // maxAge turns ago" — interpret turns as positions in the array measured
  // from the tail. If the oldest non-system message sits at index i (0-based
  // from the head), its distance from the tail is (length - 1 - i). That
  // distance must exceed maxAge.
  let oldestNonSystemIdx = -1;
  for (let i = 0; i < list.length; i++) {
    if (list[i] && list[i].role !== 'system') {
      oldestNonSystemIdx = i;
      break;
    }
  }
  let ageFromTail = 0;
  if (oldestNonSystemIdx >= 0) {
    ageFromTail = list.length - 1 - oldestNonSystemIdx;
  }
  const messageAgeHit =
    list.length >= cfg.maxMessages &&
    oldestNonSystemIdx >= 0 &&
    ageFromTail > cfg.maxAge;

  const signals = {
    tokenWatermark: {
      hit: tokenWatermarkHit,
      ratio,
      threshold: cfg.watermarkRatio,
      currentTokens,
      nCtx,
    },
    messageAge: {
      hit: messageAgeHit,
      messageCount: list.length,
      maxMessages: cfg.maxMessages,
      ageFromTail,
      maxAge: cfg.maxAge,
      oldestNonSystemIdx,
    },
  };

  if (tokenWatermarkHit) {
    return { compact: true, reason: 'token_watermark', signals };
  }
  if (messageAgeHit) {
    return { compact: true, reason: 'message_age', signals };
  }
  return { compact: false, reason: 'under_watermark', signals };
}

/**
 * Decide whether a single tool result should be elided to a stub.
 * Independent of shouldCompact — Tier 1 is always-on.
 *
 * @param {string} resultText  The tool result body (text form).
 * @param {number} [minTokens] Threshold; defaults to 2000 per §5.
 * @param {(text: string) => number | Promise<number>} tokenizer
 *        Caller-supplied tokenizer. May be sync or async.
 * @returns {boolean | Promise<boolean>}
 *        true if the result should be elided. Mirrors the tokenizer's
 *        sync/async-ness (returns a Promise iff tokenizer is async).
 */
export function shouldElideToolResult(
  resultText,
  minTokens = defaultWatermarkConfig.toolResultMinTokens,
  tokenizer,
) {
  if (typeof resultText !== 'string' || resultText.length === 0) return false;
  if (typeof tokenizer !== 'function') {
    throw new TypeError('shouldElideToolResult: tokenizer function is required');
  }
  const out = tokenizer(resultText);
  if (out && typeof out.then === 'function') {
    return out.then((n) => Number(n) >= minTokens);
  }
  return Number(out) >= minTokens;
}
