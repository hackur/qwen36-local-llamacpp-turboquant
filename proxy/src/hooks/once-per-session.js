// Built-in hook: `once-per-session`.
// Phase: `request:received`.
//
// Demonstrates the tag + early-return pattern: skip work if
// 'session-init-done' is already present in ctx.tags. Otherwise inject a
// system message (intended as session boilerplate) and tag.
//
// Note: per-request tags are not persisted across requests; "session" here
// piggybacks on the proxy's session.js prefix tracking when available — but
// the MVP uses a process-local Set keyed by the session header so the demo
// pattern is observable in tests.

const SEEN = new Set();
const TAG = "session-init-done";

export async function handler(ctx, hookConfig = {}) {
  if (ctx.tags.has(TAG)) return; // explicit early-return pattern
  const key =
    ctx.headers?.[hookConfig.session_header || "x-session-id"] ||
    ctx.requestId;
  if (SEEN.has(key)) {
    ctx.tag(TAG);
    return;
  }
  SEEN.add(key);
  const msg =
    hookConfig.message ||
    "<session-init>Proxy session opened. Compaction policies active.</session-init>";
  ctx.inject("system", msg, "before");
  ctx.tag(TAG);
}

// Test-only: clear the in-process seen-set between cases.
export function _resetForTests() {
  SEEN.clear();
}

export default handler;
