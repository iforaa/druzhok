import { describe, it, expect } from "vitest";
import { mergeSearchResults, applyTemporalDecay, applyMMR, type SearchResult } from "@druzhok/core/memory/search.js";

describe("mergeSearchResults", () => {
  it("merges vector and keyword results with weights", () => {
    const vector: SearchResult[] = [
      { id: "a", score: 0.9, text: "hello", file: "f1", startLine: 1, endLine: 1 },
      { id: "b", score: 0.7, text: "world", file: "f2", startLine: 1, endLine: 1 },
    ];
    const keyword: SearchResult[] = [
      { id: "b", score: 0.8, text: "world", file: "f2", startLine: 1, endLine: 1 },
      { id: "c", score: 0.6, text: "test", file: "f3", startLine: 1, endLine: 1 },
    ];
    const merged = mergeSearchResults(vector, keyword, { vectorWeight: 0.7, textWeight: 0.3 });
    expect(merged.length).toBe(3);
    const bResult = merged.find((r) => r.id === "b");
    expect(bResult).toBeDefined();
    expect(bResult!.score).toBeGreaterThan(0);
  });
  it("handles empty vector results", () => {
    const keyword: SearchResult[] = [{ id: "a", score: 0.5, text: "test", file: "f1", startLine: 1, endLine: 1 }];
    const merged = mergeSearchResults([], keyword, { vectorWeight: 0.7, textWeight: 0.3 });
    expect(merged.length).toBe(1);
  });
});

describe("applyTemporalDecay", () => {
  it("does not decay MEMORY.md", () => {
    const results: SearchResult[] = [{ id: "a", score: 1.0, text: "fact", file: "/workspace/MEMORY.md", startLine: 1, endLine: 1 }];
    expect(applyTemporalDecay(results, { halfLifeDays: 30 })[0].score).toBe(1.0);
  });
  it("decays old daily logs", () => {
    const oldDate = new Date(); oldDate.setDate(oldDate.getDate() - 60);
    const dateStr = oldDate.toISOString().slice(0, 10);
    const results: SearchResult[] = [{ id: "a", score: 1.0, text: "old note", file: `/workspace/memory/${dateStr}.md`, startLine: 1, endLine: 1 }];
    expect(applyTemporalDecay(results, { halfLifeDays: 30 })[0].score).toBeLessThan(0.5);
  });
  it("does not decay today's log", () => {
    const today = new Date().toISOString().slice(0, 10);
    const results: SearchResult[] = [{ id: "a", score: 1.0, text: "today", file: `/workspace/memory/${today}.md`, startLine: 1, endLine: 1 }];
    expect(applyTemporalDecay(results, { halfLifeDays: 30 })[0].score).toBeGreaterThan(0.99);
  });
});

describe("applyMMR", () => {
  it("reduces redundant results", () => {
    const results: SearchResult[] = [
      { id: "a", score: 0.9, text: "the quick brown fox jumps", file: "f1", startLine: 1, endLine: 1 },
      { id: "b", score: 0.85, text: "the quick brown fox leaps", file: "f1", startLine: 2, endLine: 2 },
      { id: "c", score: 0.7, text: "completely different topic here", file: "f2", startLine: 1, endLine: 1 },
    ];
    const reranked = applyMMR(results, { lambda: 0.5, maxResults: 2 });
    expect(reranked).toHaveLength(2);
    expect(reranked[0].id).toBe("a");
    expect(reranked[1].id).toBe("c");
  });
  it("returns all results when fewer than maxResults", () => {
    const results: SearchResult[] = [{ id: "a", score: 0.9, text: "hello", file: "f1", startLine: 1, endLine: 1 }];
    expect(applyMMR(results, { lambda: 0.7, maxResults: 5 })).toHaveLength(1);
  });
});
