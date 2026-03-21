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

export function createDelivery(api: TelegramApi): Delivery {
  return {
    async sendMessage(chatId, payload) {
      const text = payload.text?.trim();
      if (!text) return { delivered: false };
      const html = markdownToTelegramHtml(text);
      const chunks = chunkText(html, TELEGRAM_MAX_LENGTH);
      let lastMessageId: number | undefined;
      for (const chunk of chunks) {
        const result = await api.sendMessage(chatId, chunk, { parse_mode: "HTML" });
        lastMessageId = result.message_id;
      }
      return { delivered: true, messageId: lastMessageId };
    },
    async editMessage(chatId, messageId, payload) {
      const text = payload.text?.trim();
      if (!text) return;
      const html = markdownToTelegramHtml(text);
      const truncated = html.slice(0, TELEGRAM_MAX_LENGTH);
      try {
        await api.editMessageText(chatId, messageId, truncated, { parse_mode: "HTML" });
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        if (!msg.includes("not modified")) throw err;
      }
    },
    async deleteMessage(chatId, messageId) {
      await api.deleteMessage(chatId, messageId);
    },
  };
}
