export const SILENT_REPLY_TOKEN = "NO_REPLY";
export const HEARTBEAT_TOKEN = "HEARTBEAT_OK";

export function isSilentReplyText(text: string | undefined): boolean {
  if (!text) return false;
  return /^\s*NO_REPLY\s*$/.test(text);
}

export function stripSilentToken(text: string, token: string = SILENT_REPLY_TOKEN): string {
  const escaped = token.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return text.replace(new RegExp(`(?:^|\\s+)${escaped}\\s*$`), "").trim();
}

export function isHeartbeatOnly(text: string | undefined): boolean {
  if (!text) return false;
  return /^\s*HEARTBEAT_OK\s*$/.test(text);
}

export function stripHeartbeatToken(text: string): string {
  const token = HEARTBEAT_TOKEN;
  let result = text.trim();
  if (result.startsWith(token)) {
    result = result.slice(token.length).trimStart();
  }
  const endRegex = new RegExp(`${token}[^\\w]{0,4}$`);
  if (endRegex.test(result)) {
    const idx = result.lastIndexOf(token);
    result = result.slice(0, idx).trimEnd();
  }
  return result;
}
