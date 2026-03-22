import { Bot } from "grammy";
import { loadInstanceConfig } from "@druzhok/core";
import { parseInterval, createHeartbeatManager, readMemoryFile } from "@druzhok/core";
import { createRunDispatcher, runAgent, clearSession, abortRun } from "@druzhok/core";
import { spawnWorker } from "@druzhok/core";
import { enqueue } from "@druzhok/core";
import { buildInboundContext, parseCommand, createDelivery, createDraftStream } from "@druzhok/telegram";
import type { Channel, DraftStream, DraftStreamOpts } from "@druzhok/shared";
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

  // Helper to send text to a chat
  const sendToChat = async (chatId: string, text: string) => {
    await delivery.sendMessage(chatId, { text });
  };

  // Dispatcher — uses main lane, pi-coding-agent reads workspace files automatically
  // The runAgent wrapper now supports spawn_worker via onSpawnWorker callback
  const createRunAgentWithExtras = (chatId: string) => {
    return async (opts: Parameters<typeof runAgent>[0]) => {
      return runAgent({
        ...opts,
        onSendFile: async (filePath, caption) => {
          const { InputFile } = await import("grammy");
          await bot.api.sendDocument(Number(chatId), new InputFile(filePath), {
            caption: caption ?? undefined,
          });
        },
        onSetReminder: (minutes, message) => {
          console.log(`[reminder] set for ${minutes}m: "${message}"`);
          setTimeout(async () => {
            try {
              await sendToChat(chatId, `⏰ Напоминание: ${message}`);
              console.log(`[reminder] delivered: "${message}"`);
            } catch (err) {
              console.error(`[reminder] delivery failed:`, err);
            }
          }, minutes * 60 * 1000);
        },
        onSpawnWorker: (task) => {
          spawnWorker({
            task,
            notify: true,
            workspaceDir: workspace,
            proxyUrl: config.proxyUrl,
            proxyKey: config.proxyKey,
            model: config.defaultModel,
            onResult: async (payloads) => {
              for (const p of payloads) {
                if (p.text) await sendToChat(chatId, `🔧 Фоновая задача завершена:\n\n${p.text}`);
              }
            },
          });
        },
      });
    };
  };

  // Message handler
  bot.on("message", async (ctx) => {
    console.log(`[bot] message received from ${ctx.message.from?.first_name}`);
    if (ctx.message.from?.is_bot) return;
    const text = ctx.message.text ?? ctx.message.caption ?? "";
    const chatId = String(ctx.message.chat.id);

    // Commands
    if (text.startsWith("/")) {
      const parsed = parseCommand(text);
      if (parsed) {
        switch (parsed.command) {
          case "start": break; // fall through to agent
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
      // /abort — not in parseCommand's known list, handle directly
      if (text.startsWith("/abort")) {
        const abortUpdate = { message: { message_id: ctx.message.message_id, date: ctx.message.date, chat: { id: ctx.message.chat.id, type: ctx.message.chat.type as "private" | "group" | "supergroup" | "channel" }, from: ctx.message.from ? { id: ctx.message.from.id, first_name: ctx.message.from.first_name, is_bot: ctx.message.from.is_bot } : undefined, text: "" } };
        const sessionKey = buildInboundContext(abortUpdate).sessionKey;
        const aborted = await abortRun(sessionKey);
        await ctx.reply(aborted ? "Отменено." : "Нечего отменять.");
        return;
      }
    }

    // For /start, give agent a meaningful prompt
    const agentText = text === "/start"
      ? `Пользователь ${ctx.message.from?.first_name ?? "User"} только что запустил бота. Представься и начни знакомство.`
      : text;

    // Create a dispatcher with spawn_worker wired to this chat
    const dispatcher = createRunDispatcher({
      channel,
      runAgent: createRunAgentWithExtras(chatId),
      config: {
        proxyUrl: config.proxyUrl,
        proxyKey: config.proxyKey,
        defaultModel: config.defaultModel,
        workspaceDir: workspace,
        chats: config.chats,
      },
    });

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
    } catch (err) {
      console.error(`[msg] dispatch error:`, err);
    }
  });

  bot.catch((err) => {
    console.error("[bot] Grammy error:", err);
  });

  // Heartbeat — always runs, HEARTBEAT.md content is the switch
  // Empty/missing HEARTBEAT.md → tick skipped (no API call)
  // HEARTBEAT.md with content → agent runs
  const heartbeatInterval = parseInterval(config.heartbeat.every || "30m");
  if (heartbeatInterval) {
    const heartbeat = createHeartbeatManager({
      intervalMs: heartbeatInterval,
      readHeartbeatMd: () => readMemoryFile(join(workspace, "HEARTBEAT.md")),
      onTick: async () => {
        await enqueue("cron", async () => {
          console.log("[heartbeat] tick — running agent");
          // TODO: run agent with heartbeat prompt and deliver to configured chat
        });
      },
    });
    heartbeat.start();
    console.log(`  Heartbeat: every ${config.heartbeat.every || "30m"} (HEARTBEAT.md controls activation)`);
  }

  console.log("Druzhok starting...");
  console.log(`  Workspace: ${workspace}`);
  console.log(`  Model: ${config.defaultModel}`);

  bot.start({ onStart: (info) => console.log(`  Bot @${info.username} is running`) });

  process.on("SIGTERM", async () => { await bot.stop(); process.exit(0); });
  process.on("SIGINT", async () => { await bot.stop(); process.exit(0); });
}

main().catch((err) => { console.error("Fatal:", err); process.exit(1); });
