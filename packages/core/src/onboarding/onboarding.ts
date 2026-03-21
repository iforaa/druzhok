import { readFileSync, writeFileSync, existsSync, mkdirSync, unlinkSync } from "node:fs";
import { join, dirname } from "node:path";

export type OnboardingState = "needs_name" | "needs_intro" | "complete";

const ONBOARDED_MARKER = "<!-- onboarded -->";

/**
 * Check onboarding state by reading workspace files.
 * - needs_name: IDENTITY.md doesn't have a name yet
 * - needs_intro: bot is named but USER.md has no user info
 * - complete: both populated
 */
export function checkOnboardingState(workspace: string): OnboardingState {
  const identity = readFileSafe(join(workspace, "IDENTITY.md"));

  // No IDENTITY.md or name field is empty — needs name
  if (!identity || !identity.includes(ONBOARDED_MARKER)) {
    return "needs_name";
  }

  const userMd = readFileSafe(join(workspace, "USER.md"));
  if (!userMd || !userMd.includes(ONBOARDED_MARKER)) {
    return "needs_intro";
  }

  return "complete";
}

/**
 * Generate the "what's your name" greeting.
 */
export function buildNamePromptMessage(): string {
  return "Привет! Я твой новый AI-ассистент. Прежде чем начнём — как бы ты хотел меня называть?";
}

/**
 * Write the bot name into IDENTITY.md.
 */
export function saveBotName(workspace: string, botName: string): void {
  const identity = `# IDENTITY.md - Who Am I?
${ONBOARDED_MARKER}

- **Name:** ${botName}
- **Vibe:** _(figuring it out)_
- **Emoji:** _(TBD)_
`;
  const path = join(workspace, "IDENTITY.md");
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, identity);

  // Remove BOOTSTRAP.md if it exists — onboarding has started
  const bootstrapPath = join(workspace, "BOOTSTRAP.md");
  if (existsSync(bootstrapPath)) {
    try { unlinkSync(bootstrapPath); } catch {}
  }
}

/**
 * Read the bot name from IDENTITY.md.
 */
export function readBotName(workspace: string): string | null {
  const identity = readFileSafe(join(workspace, "IDENTITY.md"));
  if (!identity) return null;
  const match = identity.match(/\*\*Name:\*\*\s*(.+)/);
  return match?.[1]?.trim() || null;
}

/**
 * Build the confirmation message after naming.
 */
export function buildNameConfirmationMessage(botName: string, senderName: string): string {
  return `Отлично, я ${botName}! Приятно познакомиться, ${senderName}.\n\nРасскажи немного о себе — что тебе интересно, чем могу помочь, какие-нибудь правила — или просто спроси что-нибудь, разберёмся по ходу.`;
}

/**
 * Build a system prompt addition for the first real conversation.
 * Instructs the model to extract user preferences and save to USER.md.
 */
export function buildIntroSystemPrompt(senderName: string): string {
  return `## First Conversation — User Onboarding

This is your first real conversation with ${senderName}. As you respond:

1. Answer their message naturally and helpfully
2. Silently extract any information they share about themselves:
   - Their name and how they want to be addressed
   - Language preference (infer from the language they write in)
   - Any rules, preferences, or context they mention
3. After responding, update USER.md with what you learned:

\`\`\`
# USER.md - About Your Human
${ONBOARDED_MARKER}

- **Name:** ${senderName}
- **What to call them:** [how they want to be addressed]
- **Language:** [detected language]
- **Timezone:** [if mentioned]
- **Notes:** [any preferences or context]

## Context

[Any relevant background they shared]
\`\`\`

If they just ask a question without sharing personal info, save what you can infer (name from Telegram, language from message) and help them with their question.`;
}

/**
 * Mark intro as complete by ensuring USER.md has the onboarded marker.
 */
export function markIntroComplete(workspace: string, senderName: string): void {
  const userPath = join(workspace, "USER.md");
  const existing = readFileSafe(userPath);

  if (existing && existing.includes(ONBOARDED_MARKER)) return;

  const content = `# USER.md - About Your Human
${ONBOARDED_MARKER}

- **Name:** ${senderName}
- **What to call them:** ${senderName}
- **Language:** _(to be determined)_
- **Timezone:**
- **Notes:**

## Context

_(Getting to know you...)_
`;

  mkdirSync(dirname(userPath), { recursive: true });
  writeFileSync(userPath, content);
}

function readFileSafe(path: string): string | null {
  try { return readFileSync(path, "utf-8"); } catch { return null; }
}
