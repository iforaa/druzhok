import { describe, it, expect } from "vitest";
import { chunkMarkdown } from "@druzhok/core/memory/chunker.js";

describe("chunkMarkdown", () => {
  it("returns single chunk for short text", () => {
    const chunks = chunkMarkdown("Hello world", "test.md");
    expect(chunks).toHaveLength(1);
    expect(chunks[0].text).toBe("Hello world");
    expect(chunks[0].file).toBe("test.md");
    expect(chunks[0].startLine).toBe(1);
  });
  it("splits long text into overlapping chunks", () => {
    const line = "word ".repeat(100);
    const text = Array(10).fill(line).join("\n");
    const chunks = chunkMarkdown(text, "test.md", { targetTokens: 100, overlapTokens: 20 });
    expect(chunks.length).toBeGreaterThan(1);
  });
  it("preserves line numbers across chunks", () => {
    const lines = Array.from({ length: 20 }, (_, i) => `Line ${i + 1}`);
    const text = lines.join("\n");
    const chunks = chunkMarkdown(text, "test.md", { targetTokens: 10, overlapTokens: 2 });
    expect(chunks[0].startLine).toBe(1);
    for (let i = 1; i < chunks.length; i++) {
      expect(chunks[i].startLine).toBeGreaterThan(chunks[i - 1].startLine);
    }
  });
  it("handles empty text", () => { expect(chunkMarkdown("", "test.md")).toHaveLength(0); });
  it("returns end line for each chunk", () => {
    const text = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5";
    const chunks = chunkMarkdown(text, "test.md", { targetTokens: 5, overlapTokens: 1 });
    for (const chunk of chunks) { expect(chunk.endLine).toBeGreaterThanOrEqual(chunk.startLine); }
  });
});
