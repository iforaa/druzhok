import { describe, it, expect } from "vitest";
import { createBM25Index } from "@druzhok/core/memory/bm25.js";

describe("BM25", () => {
  const docs = [
    { id: "a", text: "the quick brown fox jumps over the lazy dog" },
    { id: "b", text: "the lazy cat sleeps all day long" },
    { id: "c", text: "a quick red fox runs through the forest" },
  ];
  it("ranks matching documents by relevance", () => {
    const index = createBM25Index(docs);
    const results = index.search("quick fox");
    expect(results.length).toBeGreaterThan(0);
    expect(results[0].id).toBe("a");
  });
  it("returns empty for no matches", () => { expect(createBM25Index(docs).search("elephant")).toHaveLength(0); });
  it("scores are positive numbers", () => {
    for (const r of createBM25Index(docs).search("lazy")) { expect(r.score).toBeGreaterThan(0); }
  });
  it("handles empty query", () => { expect(createBM25Index(docs).search("")).toHaveLength(0); });
  it("handles empty document set", () => { expect(createBM25Index([]).search("test")).toHaveLength(0); });
});
