// Tier-2/3 structured notes extractor (docs/compaction-strategy.md §6 Tier 2,
// Appendix A). For tool-result bodies that are oversized but couldn't be
// summarized by the Phase 2 small model (offline, etc.), pull out a handful of
// "memorable" tokens so the agent retains entities, decisions, and key/value
// facts even after Tier 1 elision would otherwise nuke them.
//
// Strictly heuristic. No ML. Bounded output. Returns a small array of
// `{kind, value, span}` records; `formatNotes` wraps them in the same
// `<tool_result_notes>` envelope shape as the Phase 2 summary tag so Tier 1
// recognises the result as "already short" and skips re-stubbing it.

const MAX_RECORDS = 24;

// Cheap entity-ish: CamelCase/PascalCase identifiers and dotted/underscored
// symbols at least 4 chars (function names, class names, file paths-ish).
const ENTITY_RE = /\b(?:[A-Z][a-zA-Z0-9]{2,}(?:[A-Z][a-zA-Z0-9]+)+|[A-Za-z_][\w./-]{3,}\.[A-Za-z_][\w./-]{2,})\b/g;
// key=value or key: value (e.g. status=ok, port: 11500).
const KV_RE = /\b([A-Za-z_][\w.-]{0,40})\s*[:=]\s*("[^"\n]{1,80}"|'[^'\n]{1,80}'|-?\d+(?:\.\d+)?|[A-Za-z_][\w./@-]{0,80})/g;
// Decision markers and ticket-style ids (D-12, AGREED, TODO, FIX).
const DECISION_RE = /\b(?:AGREED|DECIDED|TODO|FIXME|FIX|NOTE|WARNING|ERROR|D-\d{1,4}|[A-Z]{2,5}-\d{2,5})\b[^\n]{0,120}/g;
// Inline JSON blocks (tiny ones only — first 200 chars).
const JSON_RE = /\{[^{}\n]{2,200}\}/g;

export function extractNotesFromToolResult(body) {
  if (typeof body !== "string" || body.length === 0) return [];
  const out = [];
  const seen = new Set();
  const push = (kind, value, span) => {
    const v = String(value).trim();
    if (!v) return;
    const key = kind + "::" + v;
    if (seen.has(key)) return;
    seen.add(key);
    out.push({ kind, value: v, span });
    return out.length >= MAX_RECORDS;
  };
  for (const m of body.matchAll(DECISION_RE)) {
    if (push("decision", m[0], [m.index, m.index + m[0].length])) return out;
  }
  for (const m of body.matchAll(KV_RE)) {
    if (push("kv", `${m[1]}=${m[2]}`, [m.index, m.index + m[0].length])) return out;
  }
  for (const m of body.matchAll(ENTITY_RE)) {
    if (push("entity", m[0], [m.index, m.index + m[0].length])) return out;
  }
  for (const m of body.matchAll(JSON_RE)) {
    if (push("json", m[0], [m.index, m.index + m[0].length])) return out;
  }
  return out;
}

export function formatNotes(records, { tool } = {}) {
  const safe = (s) =>
    String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const lines = (records || []).map(
    (r) => `  <note kind="${safe(r.kind)}">${safe(r.value)}</note>`,
  );
  const toolAttr = tool ? ` tool="${safe(tool)}"` : "";
  return `<tool_result_notes${toolAttr}>\n${lines.join("\n")}\n</tool_result_notes>`;
}

// Tier-4 inline extractive summary (sumy-style LexRank-lite). No deps. Splits
// into sentences, scores by inverse position + length-in-band, returns the
// top-N joined with spaces. Determinstic.
export function sumyExtractive(body, { targetSentences = 5 } = {}) {
  if (typeof body !== "string" || !body.trim()) return "";
  const sentences = body
    .replace(/\s+/g, " ")
    .split(/(?<=[.!?])\s+(?=[A-Za-z0-9"'\[(])/)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  if (sentences.length === 0) return "";
  const scored = sentences.map((s, i) => {
    const len = s.length;
    // Penalize too-short and too-long sentences; reward early-position.
    const lenScore = len < 20 ? len / 20 : len > 400 ? 400 / len : 1;
    const posScore = 1 / (1 + i * 0.05);
    return { s, i, score: lenScore * posScore };
  });
  scored.sort((a, b) => b.score - a.score);
  const picked = scored.slice(0, targetSentences).sort((a, b) => a.i - b.i);
  return picked.map((x) => x.s).join(" ");
}
