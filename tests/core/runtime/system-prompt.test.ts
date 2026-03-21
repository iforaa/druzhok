import { describe, it, expect } from "vitest";
import { buildSystemPrompt, type SystemPromptContext } from "@druzhok/core/runtime/system-prompt.js";

const baseCtx: SystemPromptContext = {
  agentsMd: "# Instructions\nYou are helpful.",
  soulMd: "# Soul\nBe genuine.",
  identityMd: "# Identity\nName: Buddy",
  userMd: "# User\nName: Igor",
  chatSystemPrompt: undefined,
  skillsList: [],
  defaultModel: "openai/gpt-4o",
  workspaceDir: "/data/workspace",
  chatType: "direct",
};

describe("buildSystemPrompt", () => {
  it("includes AGENTS.md content", () => { expect(buildSystemPrompt(baseCtx)).toContain("You are helpful."); });
  it("includes SOUL.md content", () => { expect(buildSystemPrompt(baseCtx)).toContain("Be genuine."); });
  it("includes IDENTITY.md content", () => { expect(buildSystemPrompt(baseCtx)).toContain("Name: Buddy"); });
  it("includes USER.md in direct chats", () => { expect(buildSystemPrompt(baseCtx)).toContain("Name: Igor"); });
  it("excludes USER.md in group chats", () => {
    const p = buildSystemPrompt({ ...baseCtx, chatType: "group" });
    expect(p).not.toContain("Name: Igor");
  });
  it("includes current time", () => { expect(buildSystemPrompt(baseCtx)).toMatch(/Current time:/); });
  it("includes memory guidance", () => {
    const p = buildSystemPrompt(baseCtx);
    expect(p).toContain("MEMORY.md");
    expect(p).toContain("memory/");
  });
  it("appends per-chat system prompt", () => {
    expect(buildSystemPrompt({ ...baseCtx, chatSystemPrompt: "Be concise." })).toContain("Be concise.");
  });
  it("includes skills list when present", () => {
    const p = buildSystemPrompt({ ...baseCtx, skillsList: [{ name: "setup", description: "First-time setup" }] });
    expect(p).toContain("setup");
  });
  it("handles all null files gracefully", () => {
    const p = buildSystemPrompt({ ...baseCtx, agentsMd: null, soulMd: null, identityMd: null, userMd: null });
    expect(p).toContain("personal AI assistant");
  });
});
