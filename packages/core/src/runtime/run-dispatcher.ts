import type { InboundContext, Channel } from "@druzhok/shared";
import { processReplyPayloads } from "../reply/pipeline.js";
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
        });
        const filtered = processReplyPayloads(result.payloads, { showReasoning: false, sentTexts: [], isHeartbeat: false });
        for (const payload of filtered) { await channel.sendMessage(ctx.chatId, payload); }
      } catch (err) {
        const errorMessage = err instanceof Error ? err.message : String(err);
        await channel.sendMessage(ctx.chatId, { text: `Ошибка: ${errorMessage}`, isError: true });
      }
    },
  };
}
