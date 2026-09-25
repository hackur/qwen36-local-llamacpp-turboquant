import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { selectEvidence } from "../src/research.js";

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
