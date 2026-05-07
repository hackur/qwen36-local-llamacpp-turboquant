// Built-in hook: `tag-bash-read-elisions`.
// Phase: `request:after-rewrite`.
//
// Reads `ctx.elidedIds` (camelCase view of JSONL `elided_tool_result_ids`).
// For each elided id whose original tool name matched 'bash'/'read'
// (case-insensitive), tag the request with `elided:bash:<id>` /
// `elided:read:<id>`. Used by downstream analytics + filters.

const NAME_RE = /^(bash|read)$/i;

// Look up the tool name for a given tool_call_id by walking
// `ctx.messages` (or `ctx.outboundMessages`) for the assistant turn that
// emitted the tool_call. Returns lowercased name or null.
function findToolName(messages, callId) {
  if (!Array.isArray(messages)) return null;
  for (const m of messages) {
    if (m?.role !== "assistant") continue;
    const calls = m.tool_calls || [];
    for (const c of calls) {
      if (c?.id === callId && c.function?.name) {
        return String(c.function.name).toLowerCase();
      }
    }
  }
  return null;
}

export async function handler(ctx) {
  const ids = Array.isArray(ctx.elidedIds) ? ctx.elidedIds : [];
  if (ids.length === 0) return;
  const haystack = ctx.outboundMessages || ctx.messages || [];
  for (const id of ids) {
    const name = findToolName(haystack, id);
    if (!name || !NAME_RE.test(name)) continue;
    ctx.tag(`elided:${name}:${id}`);
    ctx.tag("bash-read-elided");
  }
}

export default handler;
