import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createSkillRegistry } from "@druzhok/core/skills/registry.js";

describe("createSkillRegistry", () => {
  let skillsDir: string;
  beforeEach(() => {
    skillsDir = mkdtempSync(join(tmpdir(), "druzhok-skills-"));
    mkdirSync(join(skillsDir, "setup"));
    writeFileSync(join(skillsDir, "setup", "SKILL.md"), '---\nname: setup\ndescription: First-time setup\ntriggers:\n  - "^/setup$"\n---\n\n# Setup Guide\n\nFollow these steps...');
    mkdirSync(join(skillsDir, "debug"));
    writeFileSync(join(skillsDir, "debug", "SKILL.md"), '---\nname: debug\ndescription: Debug helper\ntriggers:\n  - "^/debug$"\n  - "help me debug"\n---\n\n# Debug Guide\n\nCheck these things...');
  });
  afterEach(() => { rmSync(skillsDir, { recursive: true, force: true }); });

  it("discovers skills from directory", () => { expect(createSkillRegistry(skillsDir).list()).toHaveLength(2); });
  it("matches trigger by regex", () => {
    const match = createSkillRegistry(skillsDir).match("/setup");
    expect(match).not.toBeNull();
    expect(match!.name).toBe("setup");
  });
  it("matches partial trigger", () => {
    const match = createSkillRegistry(skillsDir).match("help me debug this issue");
    expect(match).not.toBeNull();
    expect(match!.name).toBe("debug");
  });
  it("returns null for no match", () => { expect(createSkillRegistry(skillsDir).match("hello world")).toBeNull(); });
  it("handles empty skills directory", () => {
    const emptyDir = mkdtempSync(join(tmpdir(), "druzhok-empty-"));
    expect(createSkillRegistry(emptyDir).list()).toHaveLength(0);
    rmSync(emptyDir, { recursive: true, force: true });
  });
});
