import type { InboundContext, ReplyContext } from "@druzhok/shared";
import { buildSessionKey } from "@druzhok/core/session/session-key.js";

type TelegramChat = { id: number; type: "private" | "group" | "supergroup" | "channel"; title?: string; is_forum?: boolean };
type TelegramUser = { id: number; first_name: string; last_name?: string; username?: string; is_bot: boolean };
type TelegramMessage = { message_id: number; date: number; chat: TelegramChat; from?: TelegramUser; text?: string; caption?: string; message_thread_id?: number; reply_to_message?: TelegramMessage };
type TelegramUpdate = { message: TelegramMessage };

function buildSenderName(user?: TelegramUser): string {
  if (!user) return "Unknown";
  const parts = [user.first_name];
  if (user.last_name) parts.push(user.last_name);
  return parts.join(" ");
}

function resolveChatType(chat: TelegramChat): "direct" | "group" {
  return chat.type === "private" ? "direct" : "group";
}

function resolveSessionKeyForChat(chat: TelegramChat, from?: TelegramUser, threadId?: number): string {
  const chatType = resolveChatType(chat);
  if (chatType === "direct") {
    return buildSessionKey({ channel: "telegram", chatType: "direct", chatId: String(from?.id ?? chat.id) });
  }
  return buildSessionKey({ channel: "telegram", chatType: "group", chatId: String(chat.id), topicId: chat.is_forum && threadId ? String(threadId) : undefined });
}

function buildReplyCtx(msg?: TelegramMessage): ReplyContext | undefined {
  if (!msg) return undefined;
  return { messageId: msg.message_id, senderId: String(msg.from?.id ?? 0), senderName: buildSenderName(msg.from), body: msg.text ?? msg.caption ?? "" };
}

export function buildInboundContext(update: TelegramUpdate): InboundContext {
  const msg = update.message;
  const chat = msg.chat;
  const from = msg.from;
  return {
    body: msg.text ?? msg.caption ?? "",
    from: `telegram:${resolveChatType(chat) === "direct" ? "dm" : "group"}:${chat.id}`,
    chatId: String(chat.id),
    chatType: resolveChatType(chat),
    senderId: String(from?.id ?? 0),
    senderName: buildSenderName(from),
    messageId: msg.message_id,
    replyTo: buildReplyCtx(msg.reply_to_message),
    sessionKey: resolveSessionKeyForChat(chat, from, msg.message_thread_id),
    timestamp: msg.date * 1000,
  };
}
