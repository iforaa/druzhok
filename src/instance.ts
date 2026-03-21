import { Bot } from "grammy";
import { loadInstanceConfig } from "@druzhok/core";
import { parseInterval, createHeartbeatManager, readMemoryFile, createSkillRegistry } from "@druzhok/core";
import { createRunDispatcher, runAgent } from "@druzhok/core";
import {
  checkOnboardingState,
  saveBotName,
  readBotName,
  buildNamePromptMessage,
  buildNameConfirmationMessage,
  buildIntroSystemPrompt,
  markIntroComplete,
} from "@druzhok/core";
import { buildInboundContext, parseCommand, createDelivery, createDraftStream } from "@druzhok/telegram";
import type { Channel, ReplyPayload, DeliveryResult, DraftStream, DraftStreamOpts } from "@druzhok/shared";
import { join } from "node:path";
import { existsSync, mkdirSync, cpSync } from "node:fs";

async function main() {
  const config = loadInstanceConfig();

  if (!config.telegramToken) { console.error("DRUZHOK_TELEGRAM_TOKEN is required"); process.exit(1); }

  // Initialize workspace
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

  // Load skills
  const skills = createSkillRegistry(join(workspace, "skills"));
  console.log(`Loaded ${skills.list().length} skills`);

  // Read workspace files (OpenClaw convention)
  const agentsMd = readMemoryFile(join(workspace, "AGENTS.md"));
  const soulMd = readMemoryFile(join(workspace, "SOUL.md"));
  const identityMd = readMemoryFile(join(workspace, "IDENTITY.md"));
  const userMd = readMemoryFile(join(workspace, "USER.md"));

  // Setup Grammy bot
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

  // Run dispatcher (recreated during onboarding when AGENTS.md changes)
  const dispatcherOpts = {
    channel,
    runAgent,
    config: {
      proxyUrl: config.proxyUrl,
      proxyKey: config.proxyKey,
      defaultModel: config.defaultModel,
      workspaceDir: workspace,
      chats: config.chats,
    },
    agentsMd,
    soulMd,
    identityMd,
    userMd,
    skillsList: skills.list(),
  };
  let dispatcher = createRunDispatcher(dispatcherOpts);

  // Grammy message handler
  bot.on("message", async (ctx) => {
    if (ctx.message.from?.is_bot) return;
    const text = ctx.message.text ?? ctx.message.caption ?? "";
    const senderName = [ctx.message.from?.first_name, ctx.message.from?.last_name].filter(Boolean).join(" ") || "User";

    // Commands
    if (text.startsWith("/")) {
      const parsed = parseCommand(text);
      if (parsed) {
        switch (parsed.command) {
          case "start": {
            const state = checkOnboardingState(workspace);
            if (state === "needs_name") {
              await ctx.reply(buildNamePromptMessage());
            } else {
              const botName = readBotName(workspace) ?? "your assistant";
              await ctx.reply(`Hello! I'm ${botName}. Send me a message!`);
            }
            return;
          }
          case "stop": await ctx.reply("Paused. Send /start to resume."); return;
          case "reset": await ctx.reply("Session reset!"); return;
          case "model":
            await ctx.reply(parsed.args ? `Model: ${parsed.args}` : `Model: ${config.defaultModel}`);
            return;
          case "prompt":
            await ctx.reply(parsed.args ? "System prompt updated." : "Use /prompt <text> to set.");
            return;
        }
      }
    }

    // Onboarding flow
    const onboardState = checkOnboardingState(workspace);

    if (onboardState === "needs_name") {
      // User is providing the bot's name
      const botName = text.trim().replace(/[^\p{L}\p{N}\s_-]/gu, "").trim() || "Druzhok";
      saveBotName(workspace, botName);
      // Reload identity for the dispatcher
      dispatcher = createRunDispatcher({
        ...dispatcherOpts,
        identityMd: readMemoryFile(join(workspace, "IDENTITY.md")),
      });
      await ctx.reply(buildNameConfirmationMessage(botName, senderName));
      return;
    }

    // Build context and dispatch to agent
    const update = {
      message: {
        message_id: ctx.message.message_id,
        date: ctx.message.date,
        chat: { id: ctx.message.chat.id, type: ctx.message.chat.type as "private" | "group" | "supergroup" | "channel" },
        from: ctx.message.from ? { id: ctx.message.from.id, first_name: ctx.message.from.first_name, last_name: ctx.message.from.last_name, is_bot: ctx.message.from.is_bot } : undefined,
        text: ctx.message.text,
        caption: ctx.message.caption,
        message_thread_id: ctx.message.message_thread_id,
      },
    };

    const inboundCtx = buildInboundContext(update);

    // If needs_intro, add onboarding system prompt and mark complete after
    if (onboardState === "needs_intro") {
      const introPrompt = buildIntroSystemPrompt(senderName);
      // Temporarily add intro instructions to the dispatch
      // Temporarily add intro instructions
      dispatcher = createRunDispatcher({
        ...dispatcherOpts,
        userMd: (dispatcherOpts.userMd ?? "") + "\n\n" + introPrompt,
      });
      await dispatcher.dispatch(inboundCtx);
      // Mark intro done and restore normal dispatcher
      markIntroComplete(workspace, senderName);
      dispatcher = createRunDispatcher({
        ...dispatcherOpts,
        userMd: readMemoryFile(join(workspace, "USER.md")),
      });
      return;
    }

    await dispatcher.dispatch(inboundCtx);
  });

  // Heartbeat
  let heartbeat: ReturnType<typeof createHeartbeatManager> | null = null;
  if (config.heartbeat.enabled) {
    const intervalMs = parseInterval(config.heartbeat.every);
    if (intervalMs) {
      heartbeat = createHeartbeatManager({
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
  const stop = async () => {
    console.log("Shutting down...");
    heartbeat?.stop();
    await bot.stop();
    console.log("Done.");
  };
  process.on("SIGTERM", () => void stop().then(() => process.exit(0)));
  process.on("SIGINT", () => void stop().then(() => process.exit(0)));
}

main().catch((err) => { console.error("Fatal:", err); process.exit(1); });
