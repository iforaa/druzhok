import type { ReplyPayload } from "@druzhok/shared";
import { createAgentSession, codingTools } from "@mariozechner/pi-coding-agent";
import type { AgentSessionEvent } from "@mariozechner/pi-coding-agent";
import type { Model } from "@mariozechner/pi-ai";

export type AgentRunOpts = {
  prompt: string;
  workspaceDir: string;
  chatSystemPrompt?: string;
  proxyUrl: string;
  proxyKey: string;
  model: string;
  onTextDelta?: (text: string, isReasoning: boolean) => void;
  onToolCallStart?: (toolName: string) => void;
  onToolCallEnd?: (toolName: string) => void;
  signal?: AbortSignal;
};

export type AgentRunResult = {
  payloads: ReplyPayload[];
  usage?: { input?: number; output?: number; total?: number };
  error?: string;
};

function buildModel(modelId: string, baseUrl: string, apiKey: string): Model<"openai-completions"> {
  const id = modelId.includes("/") ? modelId.split("/").slice(1).join("/") : modelId;
  return {
    id,
    name: id,
    api: "openai-completions",
    provider: "openai",
    baseUrl: baseUrl.replace(/\/$/, ""),
    reasoning: false,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 131072,
    maxTokens: 8192,
    headers: { Authorization: `Bearer ${apiKey}` },
  };
}

/**
 * Run the agent using pi-coding-agent.
 *
 * - cwd is set to workspaceDir so DefaultResourceLoader reads
 *   AGENTS.md, SOUL.md, IDENTITY.md, USER.md, BOOTSTRAP.md automatically
 * - codingTools gives the agent read, write, edit, bash
 * - Per-chat system prompt is appended via agent.setSystemPrompt()
 */
export async function runAgent(opts: AgentRunOpts): Promise<AgentRunResult> {
  const baseUrl = opts.proxyUrl || process.env.NEBIUS_BASE_URL || "https://api.tokenfactory.nebius.com/v1/";
  const apiKey = opts.proxyKey || process.env.NEBIUS_API_KEY || "";
  const model = buildModel(opts.model, baseUrl, apiKey);

  try {
    const { session } = await createAgentSession({
      cwd: opts.workspaceDir,
      model,
      tools: codingTools,
    });

    // Append per-chat customization if present
    if (opts.chatSystemPrompt) {
      const base = session.systemPrompt;
      session.agent.setSystemPrompt(
        `${base}\n\n## Chat-Specific Instructions\n\n${opts.chatSystemPrompt}`
      );
    }

    // Collect assistant text from events
    let fullText = "";

    session.subscribe((event: AgentSessionEvent) => {
      switch (event.type) {
        case "message_update": {
          const amEvent = event.assistantMessageEvent;
          if (amEvent.type === "text_delta") {
            fullText += amEvent.delta;
            opts.onTextDelta?.(fullText, false);
          }
          if (amEvent.type === "thinking_delta") {
            opts.onTextDelta?.(amEvent.delta, true);
          }
          break;
        }
        case "tool_execution_start":
          opts.onToolCallStart?.(event.toolName);
          break;
        case "tool_execution_end":
          opts.onToolCallEnd?.(event.toolName);
          break;
      }
    });

    await session.prompt(opts.prompt);

    const payloads: ReplyPayload[] = [];
    if (fullText.trim()) {
      payloads.push({ text: fullText.trim() });
    }

    return { payloads };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return {
      payloads: [{ text: `Ошибка: ${message}`, isError: true }],
      error: message,
    };
  }
}
