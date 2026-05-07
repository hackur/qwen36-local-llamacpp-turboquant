// Built-in hook: `context-pressure-reminder`.
// Phase: `request:before-rewrite` (MVP) — fires when prompt fraction exceeds
// the configured threshold and prepends a system reminder.
//
// Spec note: docs §8 Example 2 wires this at `stream:context-trigger` to
// write a session hint file. MVP wires at request:before-rewrite to keep the
// engine scope to request:* phases. The reminder text and trigger semantics
// are unchanged.

const DEFAULT_TEXT =
  "<reminder>Context is at {percent}% — consider compacting or summarising.</reminder>";

export async function handler(ctx, hookConfig = {}) {
  const ratio =
    typeof ctx.triggerRatio === "number"
      ? ctx.triggerRatio
      : ctx.promptTokenFraction;
  const threshold =
    typeof ctx.threshold === "number"
      ? ctx.threshold
      : (hookConfig.threshold ?? 0.75);
  if (typeof ratio !== "number" || !(ratio > threshold)) return;

  const percent = Math.round(ratio * 100);
  const text = (hookConfig.reminder_text || DEFAULT_TEXT)
    .replace("{percent}", String(percent))
    .replace("{fraction}", String(percent))
    .replace("{tokens}", String(ctx.promptTokens ?? "?"))
    .replace("{nCtx}", String(ctx.nCtx ?? "?"));

  ctx.inject("user", text, "before-final-user");
  ctx.tag("context-reminder-injected");
}

export default handler;
