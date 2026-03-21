import type { ReplyPayload } from "@druzhok/shared";
import { buildSystemPrompt, type SystemPromptContext } from "./system-prompt.js";

export type AgentRunOpts = {
  prompt: string;
  systemPromptCtx: SystemPromptContext;
  sessionDir: string;
  proxyUrl: string;
  proxyKey: string;
  model: string;
  onTextDelta?: (text: string, isReasoning: boolean) => void;
  onToolCallStart?: () => void;
  onToolCallEnd?: () => void;
  signal?: AbortSignal;
};

export type AgentRunResult = {
  payloads: ReplyPayload[];
  usage?: { input?: number; output?: number; total?: number };
  error?: string;
};

// TODO: Replace with actual pi-coding-agent integration:
// 1. createAgentSession({ cwd, model, tools })
// 2. session.on("agent_event", handler) for streaming
// 3. await session.prompt(text)
// 4. Extract payloads from result
export async function runAgent(opts: AgentRunOpts): Promise<AgentRunResult> {
  const _systemPrompt = buildSystemPrompt(opts.systemPromptCtx);
  const payloads: ReplyPayload[] = [
    { text: `[Agent not yet connected] Received: ${opts.prompt.slice(0, 100)}` },
  ];
  return { payloads };
}
