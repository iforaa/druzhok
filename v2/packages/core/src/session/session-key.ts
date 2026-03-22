export const HEARTBEAT_SESSION_KEY = "system:heartbeat";

export type SessionKeyParts = {
  channel: string;
  chatType: "direct" | "group";
  chatId: string;
  topicId?: string;
};

export function buildSessionKey(parts: {
  channel: string;
  chatType: "direct" | "group";
  chatId: string;
  topicId?: string;
}): string {
  const typeSegment = parts.chatType === "direct" ? "dm" : "group";
  let key = `${parts.channel}:${typeSegment}:${parts.chatId}`;
  if (parts.topicId) {
    key += `:topic:${parts.topicId}`;
  }
  return key;
}

export function parseSessionKey(key: string): SessionKeyParts | null {
  const dmMatch = key.match(/^(\w+):dm:(\w+)$/);
  if (dmMatch) {
    return { channel: dmMatch[1], chatType: "direct", chatId: dmMatch[2] };
  }
  const topicMatch = key.match(/^(\w+):group:(\w+):topic:(\w+)$/);
  if (topicMatch) {
    return { channel: topicMatch[1], chatType: "group", chatId: topicMatch[2], topicId: topicMatch[3] };
  }
  const groupMatch = key.match(/^(\w+):group:(\w+)$/);
  if (groupMatch) {
    return { channel: groupMatch[1], chatType: "group", chatId: groupMatch[2] };
  }
  return null;
}

export function isHeartbeatSession(key: string): boolean {
  return key === HEARTBEAT_SESSION_KEY;
}
