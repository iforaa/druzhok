import { parseCommand } from "./commands.js";

type TelegramUpdate = {
  message?: {
    message_id: number; date: number;
    chat: { id: number; type: string };
    from?: { id: number; first_name: string; is_bot: boolean };
    text?: string; caption?: string; photo?: unknown[]; voice?: unknown; document?: unknown;
  };
};

export type UpdateClassification = "command" | "message" | "ignore";

export function classifyUpdate(update: TelegramUpdate): UpdateClassification {
  const msg = update.message;
  if (!msg) return "ignore";
  if (msg.from?.is_bot) return "ignore";
  const text = msg.text ?? msg.caption ?? "";
  if (text.startsWith("/")) {
    const parsed = parseCommand(text);
    if (parsed) return "command";
  }
  if (text || msg.photo || msg.voice || msg.document) return "message";
  return "ignore";
}
