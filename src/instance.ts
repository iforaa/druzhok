import { Bot } from "grammy";
import { loadInstanceConfig } from "@druzhok/core";
import { parseInterval, createHeartbeatManager, readMemoryFile, createSkillRegistry } from "@druzhok/core";
import { createRunDispatcher, runAgent, clearSession } from "@druzhok/core";
import { buildInboundContext, parseCommand, createDelivery, createDraftStream } from "@druzhok/telegram";
import type { Channel, ReplyPayload, DeliveryResult, DraftStream, DraftStreamOpts } from "@druzhok/shared";
import { join } from "node:path";
import { existsSync, mkdirSync, cpSync } from "node:fs";

async function main() {
  const config = loadInstanceConfig();

  if (!config.telegramToken) { console.error("DRUZHOK_TELEGRAM_TOKEN is required"); process.exit(1); }

  // Initialize workspace from template if needed
  const workspace = config.workspaceDir;
  if (!existsSync(workspace)) {
    const templateDir = join(import.meta.dirname ?? ".", "..", "workspace-template");
    if (existsSync(templateDir)) {
      cpSync(templateDir, workspace, { recursive: true });
      console.log(`Initialized workspace from template at ${workspace}`);
    } else {
      mkdirSync(workspace, { recursive: true });
      mkdirSync(join(workspace, "memory"), { recursive: true });
      console.log(`Created empty workspace at ${workspace}`);
    }
  }

  // Grammy bot
  const bot = new Bot(config.telegramToken);
  const delivery = createDelivery({
    sendMessage: async (chatId, text, opts) => {
      const result = await bot.api.sendMessage(Number(chatId), text, opts as Record<string, unknown>);
      return { message_id: result.message_id };
    },
    editMessageText: async (chatId, messageId, text, opts) => {
      await bot.api.editMessageText(Number(chatId), messageId, text, opts as Record<string, unknown>);
    },
    deleteMessage: async (chatId, messageId) => {
      await bot.api.deleteMessage(Number(chatId), messageId);
    },
  });

  // Channel adapter
  const channel: Channel = {
    async start() {},
    async stop() { await bot.stop(); },
    onMessage: async () => {},
    sendMessage: (chatId, payload) => delivery.sendMessage(chatId, payload),
    editMessage: (chatId, messageId, payload) => delivery.editMessage(chatId, messageId, payload),
    deleteMessage: (chatId, messageId) => delivery.deleteMessage(chatId, messageId),
    createDraftStream(chatId: string, opts: DraftStreamOpts): DraftStream {
      return createDraftStream({
        send: async (text) => {
          const result = await bot.api.sendMessage(Number(chatId), text, { parse_mode: "HTML" });
          return result.message_id;
        },
        edit: async (messageId, text) => {
          try { await bot.api.editMessageText(Number(chatId), messageId, text, { parse_mode: "HTML" }); }
          catch (err) { if (!(err instanceof Error) || !err.message.includes("not modified")) throw err; }
        },
        minInitialChars: opts.minInitialChars ?? 30,
      });
    },
    async sendTyping(chatId) { try { await bot.api.sendChatAction(Number(chatId), "typing"); } catch {} },
    async setReaction() {},
  };

  // Dispatcher — pi-coding-agent reads workspace files (AGENTS.md, SOUL.md, etc.) automatically
  const dispatcher = createRunDispatcher({
    channel,
    runAgent,
    config: {
      proxyUrl: config.proxyUrl,
      proxyKey: config.proxyKey,
      defaultModel: config.defaultModel,
      workspaceDir: workspace,
      chats: config.chats,
    },
  });

  // Message handler — all messages go through the agent
  bot.on("message", async (ctx) => {
    if (ctx.message.from?.is_bot) return;
    const text = ctx.message.text ?? ctx.message.caption ?? "";

    // Built-in commands (only /stop, /reset, /model, /prompt handled directly)
    if (text.startsWith("/")) {
      const parsed = parseCommand(text);
      if (parsed) {
        switch (parsed.command) {
          case "start": break; // fall through to agent — let it handle onboarding
          case "stop": await ctx.reply("На паузе. Отправь /start чтобы продолжить."); return;
          case "reset": {
            const resetUpdate = { message: { message_id: ctx.message.message_id, date: ctx.message.date, chat: { id: ctx.message.chat.id, type: ctx.message.chat.type as "private" | "group" | "supergroup" | "channel" }, from: ctx.message.from ? { id: ctx.message.from.id, first_name: ctx.message.from.first_name, is_bot: ctx.message.from.is_bot } : undefined, text: "" } };
            clearSession(buildInboundContext(resetUpdate).sessionKey);
            await ctx.reply("Сессия сброшена!");
            return;
          }
          case "model":
            await ctx.reply(parsed.args ? `Модель: ${parsed.args}` : `Модель: ${config.defaultModel}`);
            return;
          case "prompt":
            await ctx.reply(parsed.args ? "Системный промпт обновлён." : "Используй /prompt <текст> чтобы задать.");
            return;
        }
      }
    }

    // For /start, give the agent a meaningful prompt instead of raw command
    const agentText = text === "/start"
      ? `Пользователь ${ctx.message.from?.first_name ?? "User"} только что запустил бота. Представься и начни знакомство.`
      : text;

    // Dispatch to agent
    console.log(`[msg] from=${ctx.message.from?.first_name} text="${agentText.slice(0, 50)}"`);
    const update = {
      message: {
        message_id: ctx.message.message_id,
        date: ctx.message.date,
        chat: { id: ctx.message.chat.id, type: ctx.message.chat.type as "private" | "group" | "supergroup" | "channel" },
        from: ctx.message.from ? { id: ctx.message.from.id, first_name: ctx.message.from.first_name, last_name: ctx.message.from.last_name, is_bot: ctx.message.from.is_bot } : undefined,
        text: agentText,
        caption: ctx.message.caption,
        message_thread_id: ctx.message.message_thread_id,
      },
    };
    try {
      await dispatcher.dispatch(buildInboundContext(update));
      console.log(`[msg] dispatch done`);
    } catch (err) {
      console.error(`[msg] dispatch error:`, err);
    }
  });

  bot.catch((err) => {
    console.error("[bot] Grammy error:", err);
  });

  // Heartbeat
  if (config.heartbeat.enabled) {
    const intervalMs = parseInterval(config.heartbeat.every);
    if (intervalMs) {
      const heartbeat = createHeartbeatManager({
        intervalMs,
        readHeartbeatMd: () => readMemoryFile(join(workspace, "HEARTBEAT.md")),
        onTick: async () => console.log("Heartbeat tick"),
      });
      heartbeat.start();
    }
  }

  console.log("Druzhok starting...");
  console.log(`  Workspace: ${workspace}`);
  console.log(`  Model: ${config.defaultModel}`);

  bot.start({ onStart: (info) => console.log(`  Bot @${info.username} is running`) });

  // Graceful shutdown
  process.on("SIGTERM", async () => { await bot.stop(); process.exit(0); });
  process.on("SIGINT", async () => { await bot.stop(); process.exit(0); });
}

main().catch((err) => { console.error("Fatal:", err); process.exit(1); });
