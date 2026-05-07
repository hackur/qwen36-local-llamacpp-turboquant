// Built-in hook: `session-hint-loader`.
// Phase: `request:received` (MVP — spec calls for `request:before-rewrite`
// priority 1; both work since both fire before rewrite).
//
// If `ctx.sessionHintPath` (or `hookConfig.path`) points at an existing
// small file, read it synchronously and prepend it as a system message.

import { existsSync, readFileSync, statSync } from "node:fs";

const MAX_BYTES = 16 * 1024;

export async function handler(ctx, hookConfig = {}) {
  const path = hookConfig.path || ctx.sessionHintPath;
  if (!path) return;
  let content;
  try {
    if (!existsSync(path)) return;
    const st = statSync(path);
    if (!st.isFile() || st.size === 0 || st.size > MAX_BYTES) return;
    content = readFileSync(path, "utf8");
  } catch {
    return; // never fail the request
  }
  if (!content) return;
  // Some hint files are JSON wrappers; surface .text if present.
  let text = content;
  try {
    const j = JSON.parse(content);
    if (j && typeof j.text === "string") text = j.text;
  } catch {
    /* plain text */
  }
  ctx.inject("system", `<session-hint>${text}</session-hint>`, "before");
  ctx.tag("session-hint-loaded");
}

export default handler;
