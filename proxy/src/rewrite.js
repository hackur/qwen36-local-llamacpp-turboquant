// Rewrite pipeline orchestrator. Wires verbatim window + Tier 1 elision into
// a single async entry point used by the server. Phase 1: Tier 0 + Tier 1 only.
// Tiers 2-4 will hook in here in later phases.
//
// Caller contract:
//   rewriteRequest({ body, tokenizer, config, cacheDir })
//     → { rewrittenBody, stats: { orig_tokens, rewritten_tokens,
//         elided_tool_result_ids } }
//
// Never throws on rewrite failure: callers should still try/catch and fall
// through to passthrough, but this module errs on the safe side internally.
import { pickVerbatim } from "./verbatim.js";
import {
  applyTier1,
  buildToolNameIndex,
  EXPAND_TOOL_DEFINITION,
} from "./tier1.js";
import { shouldCompact } from "./watermark.js";
import { summarize, buildToolResultPrompt } from "./summarizer.js";

function messageBodyText(m) {
  if (!m) return "";
  if (typeof m.content === "string") return m.content;
  if (Array.isArray(m.content)) {
    return m.content
      .map((p) => {
        if (typeof p === "string") return p;
        if (p && typeof p.text === "string") return p.text;
        if (p && typeof p.content === "string") return p.content;
        return JSON.stringify(p ?? "");
      })
      .join("\n");
  }
  return "";
}

export async function rewriteRequest({
  body,
  tokenizer,
  config,
  cacheDir,
  nCtx,
  logger,
  summarizeFn,
}) {
  const messages = Array.isArray(body?.messages) ? body.messages : [];
  const wm = config.watermarks || {};
  const verbatimOpts = {
    keepTurns: wm.verbatim_keep_turns ?? 8,
    keepTokens: wm.verbatim_keep_tokens ?? 8000,
  };

  // Pre-tokenize per-message bodies once so verbatim & tier1 can be sync.
  const perMessageText = messages.map(messageBodyText);
  const perMessageTokens = await Promise.all(
    perMessageText.map((t) => (t ? tokenizer.countTokens(t) : Promise.resolve(0))),
  );
  const origTokens = perMessageTokens.reduce((a, b) => a + b, 0);

  const { evictableIndices } = pickVerbatim(messages, {
    ...verbatimOpts,
    tokenCounts: perMessageTokens,
  });

  // For tier1 we need a sync tokenCount over arbitrary body strings — use the
  // tokenizer cache + a fallback ceil(chars/4) when uncached. Pre-warm the
  // candidate tool-result bodies so the cache hits.
  const candidates = [];
  for (const i of evictableIndices) {
    const m = messages[i];
    if (!m) continue;
    if (m.role === "tool") {
      candidates.push(messageBodyText(m));
    } else if (Array.isArray(m.content)) {
      for (const p of m.content) {
        if (p?.type === "tool_result") {
          if (typeof p.content === "string") candidates.push(p.content);
          else if (Array.isArray(p.content)) {
            for (const sub of p.content) {
              if (typeof sub === "string") candidates.push(sub);
              else if (sub?.text) candidates.push(sub.text);
            }
          }
        }
      }
    }
  }
  await Promise.all(
    candidates
      .filter((t) => t && !tokenizer.cache.get(t))
      .map((t) => tokenizer.countTokens(t).catch(() => 0)),
  );

  const syncTokenCount = (text) => {
    if (!text) return 0;
    const cached = tokenizer.cache.get(text);
    if (typeof cached === "number") return cached;
    return Math.max(1, Math.ceil(String(text).length / 4));
  };

  const toolNameFromCallId = buildToolNameIndex(messages);

  const minTokens = wm.tool_result_min_tokens ?? 2000;

  // Phase 2 hook: small-model recursive summarizer (Tier 3).
  //
  // Gate: only fire when the watermark trips AND the summarizer is configured
  // with a non-empty URL AND its mode is shadow|enforce. For each candidate
  // tool-result body that exceeds Tier-1 minTokens, attempt a summary; on
  // success in `enforce`, replace the body inline so Tier 1 sees a short
  // already-compressed payload and skips stubbing it. On any failure
  // (offline, timeout, invalid JSON, non-2xx) we fall through unchanged.
  let workingMessages = messages;
  const summarizerCfg = config.summarizer || {};
  const summarizerEnabled =
    summarizerCfg.url &&
    (summarizerCfg.mode === "shadow" || summarizerCfg.mode === "enforce");
  let summarizedCount = 0;
  if (summarizerEnabled) {
    const decision = shouldCompact(messages, {
      nCtx: nCtx || 0,
      currentTokens: origTokens,
      watermarkRatio: wm.prompt_fraction,
      maxMessages: wm.max_messages,
      maxAge: wm.max_age_turns,
    });
    if (decision.compact) {
      const fn = summarizeFn || summarize;
      const cloneMsgs = messages.map((m) =>
        m && Array.isArray(m.content)
          ? { ...m, content: m.content.map((p) => ({ ...p })) }
          : { ...m },
      );
      for (const i of evictableIndices) {
        const m = cloneMsgs[i];
        if (!m) continue;
        if (m.role === "tool") {
          const bodyText = messageBodyText(m);
          if (syncTokenCount(bodyText) < minTokens) continue;
          const tool =
            m.name || toolNameFromCallId.get(m.tool_call_id) || "unknown";
          const summary = await fn(
            buildToolResultPrompt({ tool, body: bodyText }),
            {
              url: summarizerCfg.url,
              timeoutMs: summarizerCfg.request_timeout_ms,
              maxTokens: summarizerCfg.max_tokens,
              model: summarizerCfg.model,
              logger,
            },
          );
          if (typeof summary !== "string" || summary.length === 0) continue;
          summarizedCount++;
          if (summarizerCfg.mode === "enforce") {
            const wrapped = `<tool_result_summary tool="${tool}">${summary}</tool_result_summary>`;
            cloneMsgs[i] = { ...m, content: wrapped };
          }
        } else if (Array.isArray(m.content)) {
          for (let p = 0; p < m.content.length; p++) {
            const part = m.content[p];
            if (!part || part.type !== "tool_result") continue;
            const bodyText =
              typeof part.content === "string"
                ? part.content
                : messageBodyText({ content: part.content });
            if (syncTokenCount(bodyText) < minTokens) continue;
            const callId = part.tool_use_id || part.tool_call_id;
            const tool =
              toolNameFromCallId.get(callId) || part.name || "unknown";
            const summary = await fn(
              buildToolResultPrompt({ tool, body: bodyText }),
              {
                url: summarizerCfg.url,
                timeoutMs: summarizerCfg.request_timeout_ms,
                maxTokens: summarizerCfg.max_tokens,
                model: summarizerCfg.model,
                logger,
              },
            );
            if (typeof summary !== "string" || summary.length === 0) continue;
            summarizedCount++;
            if (summarizerCfg.mode === "enforce") {
              const wrapped = `<tool_result_summary tool="${tool}">${summary}</tool_result_summary>`;
              m.content[p] = { ...part, content: wrapped };
            }
          }
        }
      }
      workingMessages = cloneMsgs;
    }
  }

  const { rewrittenMessages, elidedIds } = applyTier1({
    messages: workingMessages,
    evictableIndices,
    opts: {
      minTokens,
      cacheDir,
      tokenCount: syncTokenCount,
      toolNameFromCallId,
    },
  });

  // Inject phantom tool def if any stubs landed.
  let tools = body?.tools;
  if (elidedIds.length > 0) {
    const existing = Array.isArray(tools) ? [...tools] : [];
    const hasExpand = existing.some(
      (t) => t?.function?.name === "expand_tool_result",
    );
    if (!hasExpand) existing.push(EXPAND_TOOL_DEFINITION);
    tools = existing;
  }

  const rewrittenBody = { ...body, messages: rewrittenMessages };
  if (tools !== undefined) rewrittenBody.tools = tools;

  // Recompute rewritten token total (cheap; mostly cache hits).
  const rewrittenTexts = rewrittenMessages.map(messageBodyText);
  const rewrittenCounts = await Promise.all(
    rewrittenTexts.map((t) => (t ? tokenizer.countTokens(t) : Promise.resolve(0))),
  );
  const rewrittenTokens = rewrittenCounts.reduce((a, b) => a + b, 0);

  return {
    rewrittenBody,
    stats: {
      orig_tokens: origTokens,
      rewritten_tokens: rewrittenTokens,
      elided_tool_result_ids: elidedIds,
      summarized_count: summarizedCount,
    },
  };
}

// Detect any expand_tool_result calls in the next user/tool turn or in an
// assistant tool_calls list and answer them locally by reading the persisted
// originals. Returns null if nothing to do, else a synthesised assistant
// follow-up array of role:"tool" messages plus the matched call ids.
//
// In practice the proxy intercepts BEFORE forwarding: when an incoming request
// from the harness contains assistant messages whose tool_calls reference
// expand_tool_result with no matching tool reply yet, we splice the verbatim
// reply in instead of forwarding the call to upstream.
import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";

export function answerExpandCalls({ messages, cacheDir }) {
  if (!Array.isArray(messages)) return { messages, answered: [] };
  // Collect already-answered tool_call_ids.
  const answeredIds = new Set();
  for (const m of messages) {
    if (m?.role === "tool" && m.tool_call_id) answeredIds.add(m.tool_call_id);
  }

  const out = [];
  const answered = [];
  for (const m of messages) {
    out.push(m);
    if (m?.role !== "assistant" || !Array.isArray(m.tool_calls)) continue;
    for (const tc of m.tool_calls) {
      if (tc?.function?.name !== "expand_tool_result") continue;
      if (answeredIds.has(tc.id)) continue;
      let id;
      try {
        const args = JSON.parse(tc.function.arguments || "{}");
        id = args.id;
      } catch {
        id = null;
      }
      if (!id) {
        out.push({
          role: "tool",
          tool_call_id: tc.id,
          name: "expand_tool_result",
          content: JSON.stringify({ error: "missing id argument" }),
        });
        answered.push(tc.id);
        continue;
      }
      const path = resolve(cacheDir, "tool-results", `${id}.json`);
      if (!existsSync(path)) {
        out.push({
          role: "tool",
          tool_call_id: tc.id,
          name: "expand_tool_result",
          content: JSON.stringify({ error: `unknown id ${id}` }),
        });
        answered.push(tc.id);
        continue;
      }
      const stored = JSON.parse(readFileSync(path, "utf8"));
      const body =
        typeof stored.content === "string"
          ? stored.content
          : JSON.stringify(stored.content);
      out.push({
        role: "tool",
        tool_call_id: tc.id,
        name: "expand_tool_result",
        content: body,
      });
      answered.push(tc.id);
    }
  }
  return { messages: out, answered };
}
