import { describe, it, expect } from "vitest";
import { parseSkillFile } from "@druzhok/core/skills/loader.js";

describe("parseSkillFile", () => {
  it("parses SKILL.md with YAML frontmatter", () => {
    const content = '---\nname: setup\ndescription: First-time setup guide\ntriggers:\n  - "^/setup$"\n  - "help me set up"\n---\n\n# Setup Instructions\n\nStep 1: Install...';
    const skill = parseSkillFile(content);
    expect(skill).not.toBeNull();
    expect(skill!.name).toBe("setup");
    expect(skill!.description).toBe("First-time setup guide");
    expect(skill!.triggers).toEqual(["^/setup$", "help me set up"]);
    expect(skill!.body).toContain("# Setup Instructions");
  });
  it("returns null for file without frontmatter", () => { expect(parseSkillFile("# Just markdown")).toBeNull(); });
  it("returns null for empty file", () => { expect(parseSkillFile("")).toBeNull(); });
  it("handles frontmatter without triggers", () => {
    const skill = parseSkillFile('---\nname: info\ndescription: Info skill\n---\n\nBody text');
    expect(skill).not.toBeNull();
    expect(skill!.triggers).toEqual([]);
  });
});
