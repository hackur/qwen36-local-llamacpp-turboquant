import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { fetchPage, selectEvidence } from "../src/research.js";

describe("selectEvidence", () => {
  it("keeps topK above thresholds, sorted by caller", () => {
    const ranked = [
      { url: "a", relevance: 0.9, trust: 0.9 },
      { url: "b", relevance: 0.4, trust: 0.9 },
      { url: "c", relevance: 0.1, trust: 0.9 },
    ];
    const { passages, fallback } = selectEvidence(ranked, { topK: 3 });
    assert.equal(passages.length, 2);
    assert.equal(fallback, null);
  });
  it("returns say_no_answer_found when nothing passes", () => {
    const { passages, fallback } = selectEvidence(
      [{ url: "a", relevance: 0.1, trust: 0.1 }],
      {}
    );
    assert.equal(passages.length, 0);
    assert.equal(fallback, "say_no_answer_found");
  });
  it("hedges when best is weak but passing", () => {
    const { fallback } = selectEvidence(
      [{ url: "a", relevance: 0.4, trust: 0.9 }],
      { minRelevance: 0.3 }
    );
    assert.equal(fallback, "answer_with_hedge");
  });
});


it("fetchPage reports oversized previews instead of silently implying complete evidence", async (t) => {
  t.mock.method(globalThis, "fetch", async () => new Response("<p>" + "facts ".repeat(2000) + "</p>", {headers: {"content-type": "text/html"}}));
  const warnings = [];
  const text = await fetchPage("https://example.test/large", {logger: {warn: (...a) => warnings.push(a)}});
  assert.match(text, /\[TRUNCATED: 8000\/11999 characters/);
  assert.equal(warnings[0][0].retained_chars, 8000);
  assert.equal(warnings[0][0].total_chars, 11999);
});
