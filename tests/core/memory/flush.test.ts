import { describe, it, expect } from "vitest";
import { shouldFlush, buildFlushPrompt, isHeartbeatMdEmpty } from "@druzhok/core/memory/flush.js";

describe("shouldFlush", () => {
  it("returns true when tokens exceed threshold", () => {
    expect(shouldFlush({ estimatedTokens: 95000, contextWindow: 100000, reserveTokensFloor: 20000, softThresholdTokens: 4000, flushedThisCycle: false })).toBe(true);
  });
  it("returns false when well under threshold", () => {
    expect(shouldFlush({ estimatedTokens: 50000, contextWindow: 100000, reserveTokensFloor: 20000, softThresholdTokens: 4000, flushedThisCycle: false })).toBe(false);
  });
  it("returns false if already flushed this cycle", () => {
    expect(shouldFlush({ estimatedTokens: 95000, contextWindow: 100000, reserveTokensFloor: 20000, softThresholdTokens: 4000, flushedThisCycle: true })).toBe(false);
  });
});

describe("buildFlushPrompt", () => {
  it("returns system and user prompts", () => {
    const prompts = buildFlushPrompt();
    expect(prompts.system).toContain("compaction");
    expect(prompts.user).toContain("MEMORY.md");
    expect(prompts.user).toContain("NO_REPLY");
  });
});

describe("isHeartbeatMdEmpty", () => {
  it("returns true for empty content", () => { expect(isHeartbeatMdEmpty("")).toBe(true); });
  it("returns true for only headers", () => { expect(isHeartbeatMdEmpty("# Heartbeat\n\n## Tasks\n")).toBe(true); });
  it("returns true for empty checkboxes", () => { expect(isHeartbeatMdEmpty("# Tasks\n- [ ]\n- [ ]\n")).toBe(true); });
  it("returns false for content with tasks", () => { expect(isHeartbeatMdEmpty("# Tasks\n- Check builds\n")).toBe(false); });
  it("returns false for null (file missing)", () => { expect(isHeartbeatMdEmpty(null)).toBe(false); });
});
