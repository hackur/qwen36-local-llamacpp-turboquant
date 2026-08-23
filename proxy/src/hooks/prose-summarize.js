// Built-in hook: `prose-summarize`.
// Phase: `request:before-rewrite`.
//
// For tool-result messages whose body looks like prose (no JSON markers),
// invoke the Phase-2 summarizer and replace the body. Off by default unless
// `hookConfig.summarizer_url` is set.

import { summarize, buildToolResultPrompt } from "../summarizer.js";

const PROSE_MIN_TOKENS_DEFAULT = 500;

function looksProse(s) {
  if (typeof s !== "string" || s.length < 80) return false;
  // Quick reject: starts with JSON markers, or has structured fences.
  const head = s.trimStart().slice(0, 4);
  if (head.startsWith("{") || head.startsWith("[")) return false;
  if (s.includes("```")) return false;
  return true;
}

export async function handler(ctx, hookConfig = {}) {
  const url = hookConfig.summarizer_url || hookConfig.url;
  if (!url) return; // off-by-default
  const minTokens = hookConfig.min_prose_tokens ?? PROSE_MIN_TOKENS_DEFAULT;
  const messages = ctx.messages;
  if (!Array.isArray(messages) || messages.length === 0) return;

  for (const m of messages) {
    if (m?.role !== "tool" || typeof m.content !== "string") continue;
    if (!looksProse(m.content)) continue;
    const tokens = Math.ceil(m.content.length / 4);
    if (tokens < minTokens) continue;
    const prompt = buildToolResultPrompt({
      tool: m.name || "unknown",
      body: m.content,
    });
    const summary = await summarize(prompt, {
      url,
      timeoutMs: hookConfig.request_timeout_ms ?? 8000,
      model: hookConfig.model || "qwen3.8-local",
      maxTokens: hookConfig.max_tokens ?? 512,
    });
    if (summary) {
      m.content = `<tool_result_summary>${summary}</tool_result_summary>`;
      ctx.tag("prose-summarized");
    }
  }
}

export default handler;
