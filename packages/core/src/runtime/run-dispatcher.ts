import type { InboundContext, Channel } from "@druzhok/shared";
import { processReplyPayloads } from "../reply/pipeline.js";
import { enqueue } from "./command-queue.js";
import type { AgentRunOpts, AgentRunResult } from "./agent-run.js";

export type RunDispatcherConfig = {
  proxyUrl: string;
  proxyKey: string;
  defaultModel: string;
  workspaceDir: string;
  chats: Record<string, { systemPrompt?: string; model?: string }>;
};

export type RunDispatcherOpts = {
  channel: Channel;
  runAgent: (opts: AgentRunOpts) => Promise<AgentRunResult>;
  config: RunDispatcherConfig;
};

export type RunDispatcher = { dispatch(ctx: InboundContext): Promise<void> };

export function createRunDispatcher(opts: RunDispatcherOpts): RunDispatcher {
  const { channel, runAgent, config } = opts;
  return {
    async dispatch(ctx: InboundContext): Promise<void> {
      console.log(`[dispatch] message from ${ctx.senderName}: "${ctx.body.slice(0, 50)}"`);
      // Run in the main lane — serialized per chat
      await enqueue("main", async () => {
        console.log(`[dispatch] lane acquired, running agent`);
        await channel.sendTyping(ctx.chatId).catch(() => {});
        const chatConfig = config.chats[ctx.sessionKey];
        const model = chatConfig?.model ?? config.defaultModel;
        try {
          const result = await runAgent({
            prompt: ctx.body,
            workspaceDir: config.workspaceDir,
            chatSystemPrompt: chatConfig?.systemPrompt,
            proxyUrl: config.proxyUrl,
            proxyKey: config.proxyKey,
            model,
            sessionKey: ctx.sessionKey,
          });
          console.log(`[dispatch] agent done, payloads: ${result.payloads.length}`);
          const filtered = processReplyPayloads(result.payloads, { showReasoning: false, sentTexts: [], isHeartbeat: false });
          console.log(`[dispatch] filtered payloads: ${filtered.length}`);
          for (const payload of filtered) {
            console.log(`[dispatch] sending: "${(payload.text ?? "").slice(0, 50)}"`);
            await channel.sendMessage(ctx.chatId, payload);
          }
        } catch (err) {
          const errorMessage = err instanceof Error ? err.message : String(err);
          console.error(`[dispatch] error: ${errorMessage}`);
          if (errorMessage.includes("cleared") || errorMessage.includes("aborted")) return;
          await channel.sendMessage(ctx.chatId, { text: `Ошибка: ${errorMessage}`, isError: true });
        }
      });
    },
  };
}
