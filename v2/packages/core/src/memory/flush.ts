export type FlushCheck = { estimatedTokens: number; contextWindow: number; reserveTokensFloor: number; softThresholdTokens: number; flushedThisCycle: boolean };

export function shouldFlush(check: FlushCheck): boolean {
  if (check.flushedThisCycle) return false;
  return check.estimatedTokens >= check.contextWindow - check.reserveTokensFloor - check.softThresholdTokens;
}

export function buildFlushPrompt(): { system: string; user: string } {
  return {
    system: "Session nearing compaction. Store durable memories now. This is a silent maintenance turn — the user will not see your response.",
    user: "Write durable facts to MEMORY.md and ephemeral context to memory/YYYY-MM-DD.md (use today's date). Reply with NO_REPLY if nothing to store.",
  };
}

export function isHeartbeatMdEmpty(content: string | null | undefined): boolean {
  if (content === null || content === undefined) return false;
  for (const line of content.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    if (/^#+(\s|$)/.test(trimmed)) continue;
    if (/^[-*+]\s*(\[[\sXx]?\]\s*)?$/.test(trimmed)) continue;
    return false;
  }
  return true;
}
