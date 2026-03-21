export type SystemPromptContext = {
  agentsMd: string | null;
  soulMd: string | null;
  identityMd: string | null;
  userMd: string | null;
  chatSystemPrompt: string | undefined;
  skillsList: Array<{ name: string; description: string }>;
  defaultModel: string;
  workspaceDir: string;
  chatType: "direct" | "group";
};

export function buildSystemPrompt(ctx: SystemPromptContext): string {
  const sections: string[] = [];

  // Agent operating instructions
  if (ctx.agentsMd) sections.push(ctx.agentsMd);

  // Soul — personality
  if (ctx.soulMd) sections.push(ctx.soulMd);

  // Identity — who the bot is
  if (ctx.identityMd) sections.push(ctx.identityMd);

  // User profile — only in direct chats (privacy)
  if (ctx.chatType === "direct" && ctx.userMd) {
    sections.push(ctx.userMd);
  }

  // Default if nothing loaded
  if (sections.length === 0) {
    sections.push("You are a personal AI assistant communicating via Telegram.");
  }

  // Memory guidance
  sections.push(`## Memory

- Write durable facts (preferences, decisions, reference info) to MEMORY.md
- Write daily notes and ephemeral context to memory/YYYY-MM-DD.md (use today's date)
- When someone says "remember this," write it down immediately
- Use memory_search to recall information from previous conversations`);

  // Skills
  if (ctx.skillsList.length > 0) {
    const skillLines = ctx.skillsList.map((s) => `- **${s.name}**: ${s.description}`).join("\n");
    sections.push(`## Available Skills\n\n${skillLines}\n\nTo use a skill, read its SKILL.md file from the skills/ directory.`);
  }

  // Runtime info
  sections.push(`## Runtime

Current time: ${new Date().toISOString()}
Model: ${ctx.defaultModel}
Workspace: ${ctx.workspaceDir}`);

  // Per-chat overlay
  if (ctx.chatSystemPrompt) sections.push(`## Chat-Specific Instructions\n\n${ctx.chatSystemPrompt}`);

  return sections.join("\n\n");
}
