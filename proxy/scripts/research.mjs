#!/usr/bin/env node
import { research } from "../src/research.js";

const args = process.argv.slice(2).filter((a) => a !== "--json");
const question = args.join(" ").trim();
if (!question) {
  console.error('usage: node scripts/research.mjs "your question" [--json]');
  process.exit(2);
}
const asJson = process.argv.includes("--json");

const out = await research(question, {
  searchLimit: 10,
  topK: 3,
  logger: { warn: (...a) => console.error("[warn]", ...a) },
});

if (asJson) {
  console.log(JSON.stringify(out, null, 2));
  process.exit(0);
}
console.log(`\nQ: ${out.question}\n`);
if (!out.passages.length) {
  console.log("No trustworthy evidence found. Try rephrasing.");
  process.exit(0);
}
console.log("SOURCES:");
for (const [i, p] of out.passages.entries())
  console.log(`  [${i + 1}] ${p.title}\n      ${p.url}  (rel=${p.relevance.toFixed(2)} trust=${p.trust.toFixed(2)})`);
if (out.fallback === "answer_with_hedge") console.log("\n(!) weak evidence — hedging advised\n");
console.log("\nANSWER (qwen3.8-local):\n");
console.log(out.answer ?? "(synthesis unavailable — local server down?)");
