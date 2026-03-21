export type SystemPromptContext = {
  agentsMd: string | null;
  chatSystemPrompt: string | undefined;
  skillsList: Array<{ name: string; description: string }>;
  defaultModel: string;
  workspaceDir: string;
};

export function buildSystemPrompt(ctx: SystemPromptContext): string {
  const sections: string[] = [];
  if (ctx.agentsMd) sections.push(ctx.agentsMd);
  else sections.push("You are Druzhok, a personal AI assistant communicating via Telegram.");

  sections.push(`## Memory

- Write durable facts (preferences, decisions, reference info) to MEMORY.md
- Write daily notes and ephemeral context to memory/YYYY-MM-DD.md (use today's date)
- When someone says "remember this," write it down immediately
- Use memory_search to recall information from previous conversations`);

  if (ctx.skillsList.length > 0) {
    const skillLines = ctx.skillsList.map((s) => `- **${s.name}**: ${s.description}`).join("\n");
    sections.push(`## Available Skills\n\n${skillLines}\n\nTo use a skill, read its SKILL.md file from the skills/ directory.`);
  }

  sections.push(`## Runtime

Current time: ${new Date().toISOString()}
Model: ${ctx.defaultModel}
Workspace: ${ctx.workspaceDir}`);

  if (ctx.chatSystemPrompt) sections.push(`## Chat-Specific Instructions\n\n${ctx.chatSystemPrompt}`);

  return sections.join("\n\n");
}
