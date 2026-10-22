// Rewrite pipeline orchestrator. Wires verbatim window + Tier 1 elision into
// a single async entry point used by the server. Optional JEV routing can
// tighten Tier 0/Tier 1 thresholds; other compaction stages remain gated.
// The same single Laya pass also predicts the tool set the request needs
// (config `tool_filter`); shadow mode logs the pick, enforce mode trims the
// forwarded tools list. See docs/laya.md for the taxonomy and gates.
// Same-model summaries, notes, and extractive fallback are implemented below
// and disabled in the checked-in config.
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
import { routeLocalRequest } from "./jev.js";
import { extractNotesFromToolResult, formatNotes, sumyExtractive } from "./notes.js";

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
  const jevCfg = config.jev || {};
  // Phase 7 shared classifier pass. Routing and tool-set prediction ride ONE
  // /v1/systemone call: when tool_filter is armed (taxonomy set, mode
  // shadow|enforce, tools in body) the same pass also asks the `toolset`
  // question, so the classifier hot path costs one request regardless of how
  // many consumers are active. The tool_filter section's local_url/model win
  // over the jev section for the shared call when set (checked-in config
  // keeps both identical); the timeout is the max of both so neither consumer
  // is cut short.
  const filterCfg = config.tool_filter || {};
  const filterMode = filterCfg.mode || "shadow";
  const taxonomy = filterCfg.taxonomy && typeof filterCfg.taxonomy === "object" ? filterCfg.taxonomy : null;
  const filterArmed = Boolean(taxonomy) && (filterMode === "shadow" || filterMode === "enforce") && Array.isArray(body?.tools) && body.tools.length > 0;
  const classifyUrl = filterCfg.local_url || jevCfg.local_url;
  const classifyModel = filterCfg.model || jevCfg.model;
  const classifyTimeout = Math.max(jevCfg.timeout_ms ?? 300, filterCfg.timeout_ms ?? 300);
  let jevRoute = null;
  let jevConfidence = 0;
  let toolsetChoice = null;
  let toolsetConfidence = 0;
  if (classifyUrl) {
    try {
      const lastUser = [...messages].reverse().find((m) => m?.role === "user");
      const stateText = typeof lastUser?.content === "string" ? lastUser.content : JSON.stringify(lastUser?.content ?? messages.slice(-3));
      const jr = await routeLocalRequest(stateText.slice(0, 4000), {
        localUrl: classifyUrl,
        model: classifyModel,
        mode: jevCfg.mode || "local-first",
        timeoutMs: classifyTimeout,
        toolsetCriteria: filterArmed ? taxonomy : undefined,
      });
      if (jr) {
        jevRoute = jr.route;
        jevConfidence = jr.routeConfidence ?? 0;
        toolsetChoice = jr.toolset ?? null;
        toolsetConfidence = jr.toolsetConfidence ?? 0;
      }
    } catch { jevRoute = null; }
  }
  const jevForced = jevRoute === "compact" && jevConfidence >= 0.6;
  const verbatimOpts = {
    keepTurns: jevForced ? Math.min(wm.verbatim_keep_turns ?? 8, 2) : (wm.verbatim_keep_turns ?? 8),
    keepTokens: jevForced ? Math.min(wm.verbatim_keep_tokens ?? 8000, 2000) : (wm.verbatim_keep_tokens ?? 8000),
  };
  const perMessageText = messages.map(messageBodyText);
  const perMessageTokens = await Promise.all(perMessageText.map((t) => (t ? tokenizer.countTokens(t) : Promise.resolve(0))));
  const origTokens = perMessageTokens.reduce((a, b) => a + b, 0);
  const { evictableIndices } = pickVerbatim(messages, { ...verbatimOpts, tokenCounts: perMessageTokens });

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
  let minTokens = wm.tool_result_min_tokens ?? 2000;
  if (jevForced) minTokens = Math.min(minTokens, 500);

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

  // Phase 4/5 hook: structured notes (Tier-2/3) + sumy extractive fallback
  // (Tier-4). Both gated, both off by default. We only act on tool-result
  // bodies that:
  //   - exceed Tier-1 minTokens (so they'd otherwise be stubbed), AND
  //   - were NOT already replaced by the Phase 2 summarizer (we recognise
  //     that by the `<tool_result_summary` envelope), AND
  //   - the watermark has tripped (same gate Phase 2 uses).
  // On a hit we replace the body with a `<tool_result_notes>` (or sumy
  // `<tool_result_summary>`) envelope, in the same shape Tier 1 treats as
  // already-short, so Tier 1 will not re-stub it.
  const notesCfg = config.notes || {};
  const sumyCfg = config.sumy || {};
  let notesCount = 0;
  let sumyUsed = 0;
  const notesEnabled = notesCfg.enabled === true;
  const sumyEnabled = sumyCfg.enabled === true;
  if (notesEnabled || sumyEnabled) {
    const decision = shouldCompact(messages, {
      nCtx: nCtx || 0,
      currentTokens: origTokens,
      watermarkRatio: wm.prompt_fraction,
      maxMessages: wm.max_messages,
      maxAge: wm.max_age_turns,
    });
    if (decision.compact) {
      const notesMin = notesCfg.min_tokens_to_extract ?? minTokens;
      const sumyTarget = sumyCfg.target_sentences ?? 5;
      const alreadyCompressed = (s) =>
        typeof s === "string" &&
        (/^<tool_result_summary\b/.test(s) || /^<tool_result_notes\b/.test(s));
      // Make sure we have a writable clone (Phase 2 may or may not have made one).
      if (workingMessages === messages) {
        workingMessages = messages.map((m) =>
          m && Array.isArray(m.content)
            ? { ...m, content: m.content.map((p) => ({ ...p })) }
            : { ...m },
        );
      }
      const tryReplace = (bodyText, tool) => {
        if (notesEnabled && syncTokenCount(bodyText) >= notesMin) {
          const recs = extractNotesFromToolResult(bodyText);
          if (recs.length > 0) {
            notesCount++;
            return formatNotes(recs, { tool });
          }
        }
        if (sumyEnabled) {
          const summary = sumyExtractive(bodyText, { targetSentences: sumyTarget });
          if (summary) {
            sumyUsed++;
            return `<tool_result_summary tool="${tool}" source="sumy">${summary}</tool_result_summary>`;
          }
        }
        return null;
      };
      for (const i of evictableIndices) {
        const m = workingMessages[i];
        if (!m) continue;
        if (m.role === "tool") {
          const bodyText = messageBodyText(m);
          if (!bodyText || alreadyCompressed(bodyText)) continue;
          if (syncTokenCount(bodyText) < minTokens) continue;
          const tool =
            m.name || toolNameFromCallId.get(m.tool_call_id) || "unknown";
          const replacement = tryReplace(bodyText, tool);
          if (replacement) workingMessages[i] = { ...m, content: replacement };
        } else if (Array.isArray(m.content)) {
          for (let p = 0; p < m.content.length; p++) {
            const part = m.content[p];
            if (!part || part.type !== "tool_result") continue;
            const bodyText =
              typeof part.content === "string"
                ? part.content
                : messageBodyText({ content: part.content });
            if (!bodyText || alreadyCompressed(bodyText)) continue;
            if (syncTokenCount(bodyText) < minTokens) continue;
            const callId = part.tool_use_id || part.tool_call_id;
            const tool =
              toolNameFromCallId.get(callId) || part.name || "unknown";
            const replacement = tryReplace(bodyText, tool);
            if (replacement) m.content[p] = { ...part, content: replacement };
          }
        }
      }
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

  // Phase 7 gate: apply the tool-set prediction from the shared Laya pass at
  // the top of this function. When the classifier picks a known tool set (or
  // "all") with confidence above the gate, enforce mode forwards the request
  // with ONLY that set's tools so a capable but context-bloat-prone model
  // gets a shorter, clearer tool surface. Below gate, unknown label,
  // classifier down, or no tools in the body: passthrough (no filter, no
  // loss). Shadow mode never drops tools; it records the decision in stats
  // for offline tuning before enforce is enabled.
  const filterGate = typeof filterCfg.confidence === "number" ? filterCfg.confidence : 0.6;
  const toolsByName = (list) => {
    const m = new Map();
    for (const t of list || []) {
      const n = t?.function?.name;
      if (n && !m.has(n)) m.set(n, t);
    }
    return m;
  };
  const toolNames = (list) => [...toolsByName(list).keys()];
  const allTools = toolsByName(body?.tools);
  const pickTools = (names) => {
    return [...new Set(names)].filter((n) => allTools.has(n)).map((n) => allTools.get(n));
  };
  let toolFilter = null;
  if (filterArmed) {
    // Boolean coercion matters: a null choice (classifier down) must yield
    // passes === false, not `null`, or telemetry consumers comparing
    // strictly see an ambiguous verdict.
    const inTaxonomy = Boolean(toolsetChoice) && Object.prototype.hasOwnProperty.call(taxonomy, toolsetChoice);
    const isAll = inTaxonomy && taxonomy[toolsetChoice] === "all";
    const passes = toolsetChoice === "all" || isAll || (inTaxonomy && Array.isArray(taxonomy[toolsetChoice]) && toolsetConfidence >= filterGate);
    const selectedNames = toolsetChoice === "all" || isAll ? toolNames(body.tools) : (inTaxonomy && Array.isArray(taxonomy[toolsetChoice]) ? taxonomy[toolsetChoice] : []);
    const selectedKnown = toolNames(pickTools(selectedNames));
    toolFilter = { choice: toolsetChoice, confidence: toolsetConfidence, passes, selected: passes ? selectedKnown : toolNames(body.tools), dropped: passes ? toolNames(body.tools).filter((n) => !selectedKnown.includes(n)) : [] };
    if (passes && filterMode === "enforce") {
      body.tools = pickTools(selectedNames);
    }
  }

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
      notes_count: notesCount,
      sumy_used: sumyUsed,
      jev_route: jevRoute,
      jev_confidence: jevConfidence,
      tool_filter: toolFilter ? { choice: toolFilter.choice, confidence: toolFilter.confidence, passes: toolFilter.passes, mode: filterMode, selected: toolFilter.selected, dropped: toolFilter.dropped } : null,
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
