import type { ReplyPayload } from "@druzhok/shared";
import { isSilentReplyText, stripSilentToken, isHeartbeatOnly, stripHeartbeatToken } from "@druzhok/shared";

export function filterSilentReplies(payloads: ReplyPayload[]): ReplyPayload[] {
  return payloads.map((p) => {
    if (!p.text) return p;
    if (isSilentReplyText(p.text)) return null;
    const stripped = stripSilentToken(p.text);
    if (!stripped) return null;
    return stripped !== p.text ? { ...p, text: stripped } : p;
  }).filter((p): p is ReplyPayload => p !== null);
}

export function filterReasoningBlocks(payloads: ReplyPayload[], showReasoning: boolean): ReplyPayload[] {
  if (showReasoning) return payloads;
  return payloads.filter((p) => !p.isReasoning);
}

export function filterEmptyPayloads(payloads: ReplyPayload[]): ReplyPayload[] {
  return payloads.filter((p) => {
    const hasText = p.text && p.text.trim().length > 0;
    const hasMedia = p.mediaUrl || (p.mediaUrls && p.mediaUrls.length > 0);
    return hasText || hasMedia;
  });
}

export function deduplicateAgainstSent(payloads: ReplyPayload[], sentTexts: string[]): ReplyPayload[] {
  if (sentTexts.length === 0) return payloads;
  const sentSet = new Set(sentTexts.map((t) => t.trim()));
  return payloads.filter((p) => !p.text || !sentSet.has(p.text.trim()));
}

export function stripHeartbeatFromPayloads(payloads: ReplyPayload[]): ReplyPayload[] {
  return payloads.map((p) => {
    if (!p.text) return p;
    if (isHeartbeatOnly(p.text)) return null;
    const stripped = stripHeartbeatToken(p.text);
    if (!stripped) return null;
    return stripped !== p.text ? { ...p, text: stripped } : p;
  }).filter((p): p is ReplyPayload => p !== null);
}
