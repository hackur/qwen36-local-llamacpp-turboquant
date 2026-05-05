// Tier 0 verbatim window selection (docs/compaction-strategy.md §6 Tier 0).
//
// Pure function. No I/O, no tokenizer call — token counts are passed in.
//
// Always preserved:
//   - All system messages (role === "system").
//   - The current (last) user turn.
//   - The last K turns OR the last K tokens, whichever covers MORE messages
//     (defaults: 8 turns / 8000 tokens).
//
// Tool definitions live on the request body (not in `messages`), so they're
// preserved by the caller; this module only inspects messages.

const DEFAULT_KEEP_TURNS = 8;
const DEFAULT_KEEP_TOKENS = 8000;

// A "turn" is a single non-system message. We count from the tail.
export function pickVerbatim(messages, opts = {}) {
  const keepTurns = opts.keepTurns ?? DEFAULT_KEEP_TURNS;
  const keepTokens = opts.keepTokens ?? DEFAULT_KEEP_TOKENS;
  const tokenCounts = opts.tokenCounts || []; // index-aligned; missing = 0

  const verbatim = new Set();
  if (!Array.isArray(messages) || messages.length === 0) {
    return { verbatimIndices: verbatim, evictableIndices: [] };
  }

  // System messages: always.
  for (let i = 0; i < messages.length; i++) {
    if (messages[i]?.role === "system") verbatim.add(i);
  }

  // Current (last) user turn — the last message whose role === "user".
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i]?.role === "user") {
      verbatim.add(i);
      break;
    }
  }

  // Walk from the tail keeping turns until BOTH thresholds are satisfied
  // ("whichever is larger" — we keep at least keepTurns turns AND at least
  // keepTokens worth, so we stop only once both bounds are met).
  let turnsKept = 0;
  let tokensKept = 0;
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i];
    if (!m || m.role === "system") continue;
    const turnSatisfied = turnsKept >= keepTurns;
    const tokSatisfied = tokensKept >= keepTokens;
    if (turnSatisfied && tokSatisfied) break;
    verbatim.add(i);
    turnsKept += 1;
    tokensKept += tokenCounts[i] || 0;
  }

  const evictable = [];
  for (let i = 0; i < messages.length; i++) {
    if (!verbatim.has(i)) evictable.push(i);
  }
  return { verbatimIndices: verbatim, evictableIndices: evictable };
}

export const VERBATIM_DEFAULTS = {
  keepTurns: DEFAULT_KEEP_TURNS,
  keepTokens: DEFAULT_KEEP_TOKENS,
};
