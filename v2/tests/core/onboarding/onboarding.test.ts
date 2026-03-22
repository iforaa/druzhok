import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  checkOnboardingState,
  saveBotName,
  readBotName,
  buildNamePromptMessage,
  buildNameConfirmationMessage,
  buildIntroSystemPrompt,
  markIntroComplete,
} from "@druzhok/core/onboarding/onboarding.js";

describe("onboarding", () => {
  let workspace: string;

  beforeEach(() => { workspace = mkdtempSync(join(tmpdir(), "druzhok-onboard-")); });
  afterEach(() => { rmSync(workspace, { recursive: true, force: true }); });

  describe("checkOnboardingState", () => {
    it("returns needs_name when no IDENTITY.md", () => {
      expect(checkOnboardingState(workspace)).toBe("needs_name");
    });
    it("returns needs_name when IDENTITY.md has no onboarded marker", () => {
      writeFileSync(join(workspace, "IDENTITY.md"), "# Identity\nEmpty template");
      expect(checkOnboardingState(workspace)).toBe("needs_name");
    });
    it("returns needs_intro after bot is named but no USER.md", () => {
      saveBotName(workspace, "Buddy");
      expect(checkOnboardingState(workspace)).toBe("needs_intro");
    });
    it("returns complete when both files have markers", () => {
      saveBotName(workspace, "Buddy");
      markIntroComplete(workspace, "Igor");
      expect(checkOnboardingState(workspace)).toBe("complete");
    });
  });

  describe("saveBotName", () => {
    it("writes IDENTITY.md with bot name", () => {
      saveBotName(workspace, "Buddy");
      const content = readFileSync(join(workspace, "IDENTITY.md"), "utf-8");
      expect(content).toContain("**Name:** Buddy");
      expect(content).toContain("<!-- onboarded -->");
    });
    it("removes BOOTSTRAP.md if it exists", () => {
      writeFileSync(join(workspace, "BOOTSTRAP.md"), "first run stuff");
      saveBotName(workspace, "Buddy");
      expect(() => readFileSync(join(workspace, "BOOTSTRAP.md"))).toThrow();
    });
  });

  describe("readBotName", () => {
    it("reads name from IDENTITY.md", () => {
      saveBotName(workspace, "Buddy");
      expect(readBotName(workspace)).toBe("Buddy");
    });
    it("returns null when no IDENTITY.md", () => {
      expect(readBotName(workspace)).toBeNull();
    });
  });

  describe("buildNamePromptMessage", () => {
    it("asks for a name", () => { expect(buildNamePromptMessage()).toContain("называть"); });
  });

  describe("buildNameConfirmationMessage", () => {
    it("includes bot name and sender name", () => {
      const msg = buildNameConfirmationMessage("Buddy", "Igor");
      expect(msg).toContain("Buddy");
      expect(msg).toContain("Igor");
    });
  });

  describe("buildIntroSystemPrompt", () => {
    it("includes USER.md instructions", () => {
      const prompt = buildIntroSystemPrompt("Igor");
      expect(prompt).toContain("Igor");
      expect(prompt).toContain("USER.md");
    });
  });

  describe("markIntroComplete", () => {
    it("creates USER.md with marker", () => {
      markIntroComplete(workspace, "Igor");
      const content = readFileSync(join(workspace, "USER.md"), "utf-8");
      expect(content).toContain("<!-- onboarded -->");
      expect(content).toContain("Igor");
    });
    it("does not duplicate if marker already exists", () => {
      writeFileSync(join(workspace, "USER.md"), "# User\n<!-- onboarded -->\nStuff");
      markIntroComplete(workspace, "Igor");
      const content = readFileSync(join(workspace, "USER.md"), "utf-8");
      expect((content.match(/<!-- onboarded -->/g) || []).length).toBe(1);
    });
  });
});
