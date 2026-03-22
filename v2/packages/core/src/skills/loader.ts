export type Skill = { name: string; description: string; triggers: string[]; body: string };

export function parseSkillFile(content: string): Skill | null {
  if (!content) return null;
  const match = content.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!match) return null;
  const frontmatter = match[1];
  const body = match[2].trim();
  const name = extractField(frontmatter, "name");
  if (!name) return null;
  const description = extractField(frontmatter, "description");
  const triggers = extractList(frontmatter, "triggers");
  return { name, description: description ?? "", triggers, body };
}

function extractField(yaml: string, field: string): string | null {
  const match = yaml.match(new RegExp(`^${field}:\\s*(.+)$`, "m"));
  return match ? match[1].trim().replace(/^["']|["']$/g, "") : null;
}

function extractList(yaml: string, field: string): string[] {
  const lines = yaml.split("\n");
  const items: string[] = [];
  let inList = false;
  for (const line of lines) {
    if (line.match(new RegExp(`^${field}:`))) { inList = true; continue; }
    if (inList) {
      const m = line.match(/^\s+-\s+"?([^"]*)"?\s*$/);
      if (m) items.push(m[1]);
      else if (!line.match(/^\s/)) break;
    }
  }
  return items;
}
