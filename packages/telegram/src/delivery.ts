import type { ReplyPayload, DeliveryResult } from "@druzhok/shared";
import { markdownToTelegramHtml, chunkText } from "./format.js";

const TELEGRAM_MAX_LENGTH = 4096;

export type TelegramApi = {
  sendMessage(chatId: string, text: string, opts: Record<string, unknown>): Promise<{ message_id: number }>;
  editMessageText(chatId: string, messageId: number, text: string, opts: Record<string, unknown>): Promise<unknown>;
  deleteMessage(chatId: string, messageId: number): Promise<unknown>;
};

export type Delivery = {
  sendMessage(chatId: string, payload: ReplyPayload): Promise<DeliveryResult>;
  editMessage(chatId: string, messageId: number, payload: ReplyPayload): Promise<void>;
  deleteMessage(chatId: string, messageId: number): Promise<void>;
};

/**
 * Try sending as HTML, fall back to plain text if Telegram rejects the markup.
 */
async function sendWithFallback(
  api: TelegramApi,
  chatId: string,
  text: string,
): Promise<{ message_id: number }> {
  try {
    return await api.sendMessage(chatId, markdownToTelegramHtml(text), { parse_mode: "HTML" });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes("can't parse entities") || msg.includes("Bad Request")) {
      // HTML was broken — send as plain text
      return await api.sendMessage(chatId, text, {});
    }
    throw err;
  }
}

export function createDelivery(api: TelegramApi): Delivery {
  return {
    async sendMessage(chatId, payload) {
      const text = payload.text?.trim();
      if (!text) return { delivered: false };
      const chunks = chunkText(text, TELEGRAM_MAX_LENGTH);
      let lastMessageId: number | undefined;
      for (const chunk of chunks) {
        const result = await sendWithFallback(api, chatId, chunk);
        lastMessageId = result.message_id;
      }
      return { delivered: true, messageId: lastMessageId };
    },
    async editMessage(chatId, messageId, payload) {
      const text = payload.text?.trim();
      if (!text) return;
      try {
        const html = markdownToTelegramHtml(text);
        await api.editMessageText(chatId, messageId, html.slice(0, TELEGRAM_MAX_LENGTH), { parse_mode: "HTML" });
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        if (msg.includes("not modified")) return;
        if (msg.includes("can't parse entities") || msg.includes("Bad Request")) {
          // Fallback to plain text
          await api.editMessageText(chatId, messageId, text.slice(0, TELEGRAM_MAX_LENGTH), {});
          return;
        }
        throw err;
      }
    },
    async deleteMessage(chatId, messageId) {
      await api.deleteMessage(chatId, messageId);
    },
  };
}
