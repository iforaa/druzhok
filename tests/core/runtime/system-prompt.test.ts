import { describe, it, expect } from "vitest";
import { buildSystemPrompt, type SystemPromptContext } from "@druzhok/core/runtime/system-prompt.js";

const baseCtx: SystemPromptContext = {
  agentsMd: "# Druzhok\nYou are helpful.",
  chatSystemPrompt: undefined,
  skillsList: [],
  defaultModel: "openai/gpt-4o",
  workspaceDir: "/data/workspace",
};

describe("buildSystemPrompt", () => {
  it("includes AGENTS.md content", () => { expect(buildSystemPrompt(baseCtx)).toContain("You are helpful."); });
  it("includes current time", () => { expect(buildSystemPrompt(baseCtx)).toMatch(/Current time:/); });
  it("includes memory guidance", () => {
    const p = buildSystemPrompt(baseCtx);
    expect(p).toContain("MEMORY.md");
    expect(p).toContain("memory/");
  });
  it("appends per-chat system prompt", () => {
    expect(buildSystemPrompt({ ...baseCtx, chatSystemPrompt: "Be concise and technical." })).toContain("Be concise and technical.");
  });
  it("includes skills list when present", () => {
    const p = buildSystemPrompt({ ...baseCtx, skillsList: [{ name: "setup", description: "First-time setup" }, { name: "debug", description: "Debug helper" }] });
    expect(p).toContain("setup");
    expect(p).toContain("debug");
  });
  it("handles missing AGENTS.md", () => {
    const p = buildSystemPrompt({ ...baseCtx, agentsMd: null });
    expect(p).toBeTruthy();
    expect(p).toContain("MEMORY.md");
  });
});
