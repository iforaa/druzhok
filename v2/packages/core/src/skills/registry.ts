import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { parseSkillFile, type Skill } from "./loader.js";

type CompiledSkill = Skill & { compiledTriggers: RegExp[] };
export type SkillRegistry = { list(): Array<{ name: string; description: string }>; match(text: string): Skill | null };

export function createSkillRegistry(skillsDir: string): SkillRegistry {
  const skills: CompiledSkill[] = [];
  if (!existsSync(skillsDir)) return { list: () => [], match: () => null };
  for (const entry of readdirSync(skillsDir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const skillPath = join(skillsDir, entry.name, "SKILL.md");
    if (!existsSync(skillPath)) continue;
    try {
      const content = readFileSync(skillPath, "utf-8");
      const skill = parseSkillFile(content);
      if (!skill) continue;
      const compiledTriggers = skill.triggers.map((t) => { try { return new RegExp(t, "i"); } catch { return null; } }).filter((r): r is RegExp => r !== null);
      skills.push({ ...skill, compiledTriggers });
    } catch { /* skip malformed */ }
  }
  return {
    list() { return skills.map((s) => ({ name: s.name, description: s.description })); },
    match(text: string) {
      for (const skill of skills) { for (const trigger of skill.compiledTriggers) { if (trigger.test(text)) return skill; } }
      return null;
    },
  };
}
