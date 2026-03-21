import type { ReplyPayload } from "@druzhok/shared";
import { createAgentSession, codingTools, AuthStorage } from "@mariozechner/pi-coding-agent";
import type { AgentSession, AgentSessionEvent, ToolDefinition } from "@mariozechner/pi-coding-agent";
import type { Model } from "@mariozechner/pi-ai";
import { Type } from "@mariozechner/pi-ai";

export type AgentRunOpts = {
  prompt: string;
  workspaceDir: string;
  chatSystemPrompt?: string;
  proxyUrl: string;
  proxyKey: string;
  model: string;
  sessionKey?: string;
  onTextDelta?: (text: string, isReasoning: boolean) => void;
  onToolCallStart?: (toolName: string) => void;
  onToolCallEnd?: (toolName: string) => void;
  onSpawnWorker?: (task: string) => void;
  onSendFile?: (filePath: string, caption?: string) => Promise<void>;
  signal?: AbortSignal;
};

export type AgentRunResult = {
  payloads: ReplyPayload[];
  usage?: { input?: number; output?: number; total?: number };
  error?: string;
};

const REASONING_MODEL_PATTERNS = [
  /kimi/i, /deepseek.*r1/i, /thinking/i, /qwen3.*thinking/i,
];

function isReasoningModel(id: string): boolean {
  return REASONING_MODEL_PATTERNS.some((p) => p.test(id));
}

function buildModel(modelId: string, baseUrl: string, apiKey: string): Model<"openai-completions"> {
  const id = modelId.includes("/") ? modelId.split("/").slice(1).join("/") : modelId;
  const reasoning = isReasoningModel(id);
  return {
    id,
    name: id,
    api: "openai-completions",
    provider: "openai",
    baseUrl: baseUrl.replace(/\/$/, ""),
    reasoning,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: 131072,
    maxTokens: 16384,
    headers: { Authorization: `Bearer ${apiKey}` },
    compat: {
      maxTokensField: "max_tokens",
      supportsStore: false,
      supportsDeveloperRole: false,
    },
  };
}

// Session cache: reuse sessions across messages for conversation continuity
const sessionCache = new Map<string, AgentSession>();

async function getOrCreateSession(opts: {
  sessionKey: string;
  workspaceDir: string;
  model: Model<"openai-completions">;
  apiKey: string;
  chatSystemPrompt?: string;
  onSpawnWorker?: (task: string) => void;
  onSendFile?: (filePath: string, caption?: string) => Promise<void>;
}): Promise<AgentSession> {
  const cached = sessionCache.get(opts.sessionKey);
  if (cached) return cached;

  const authStorage = AuthStorage.inMemory();
  authStorage.setRuntimeApiKey("openai", opts.apiKey);

  // Custom tools
  const customTools: ToolDefinition[] = [];

  if (opts.onSendFile) {
    const onSend = opts.onSendFile;
    customTools.push({
      name: "send_file",
      label: "Send File",
      description: "Send a file to the user via Telegram. Use this to send documents, images, PDFs, etc. The file must exist on disk.",
      parameters: Type.Object({
        path: Type.String({ description: "Absolute path to the file to send" }),
        caption: Type.Optional(Type.String({ description: "Optional caption for the file" })),
      }),
      async execute(_toolCallId, params: { path: string; caption?: string }) {
        try {
          await onSend(params.path, params.caption);
          return {
            content: [{ type: "text" as const, text: `File sent: ${params.path}` }],
            details: {},
          };
        } catch (err) {
          return {
            content: [{ type: "text" as const, text: `Failed to send file: ${err instanceof Error ? err.message : String(err)}` }],
            details: {},
          };
        }
      },
    });
  }

  if (opts.onSpawnWorker) {
    const onSpawn = opts.onSpawnWorker;
    customTools.push({
      name: "spawn_worker",
      label: "Spawn Worker",
      description: "Spawn a background worker for a long-running task. The worker runs independently and sends results to the user when done. Use this when a task will take a long time and you want to keep the conversation responsive.",
      parameters: Type.Object({
        task: Type.String({ description: "Detailed description of what the worker should do" }),
      }),
      async execute(_toolCallId, params: { task: string }) {
        onSpawn(params.task);
        return {
          content: [{ type: "text" as const, text: "Worker spawned. I'll notify the user when it's done." }],
          details: {},
        };
      },
    });
  }

  const { session } = await createAgentSession({
    cwd: opts.workspaceDir,
    model: opts.model,
    tools: codingTools,
    customTools,
    authStorage,
  });

  // Append per-chat customization if present
  if (opts.chatSystemPrompt) {
    const base = session.systemPrompt;
    session.agent.setSystemPrompt(
      `${base}\n\n## Chat-Specific Instructions\n\n${opts.chatSystemPrompt}`
    );
  }

  sessionCache.set(opts.sessionKey, session);
  return session;
}

export function clearSession(sessionKey: string): void {
  sessionCache.delete(sessionKey);
  activeRuns.delete(sessionKey);
}

// Track active runs for abort support
const activeRuns = new Map<string, { abort: () => Promise<void> }>();

/**
 * Abort the active run for a session. Returns true if a run was aborted.
 */
export async function abortRun(sessionKey: string): Promise<boolean> {
  const run = activeRuns.get(sessionKey);
  if (!run) return false;
  await run.abort();
  activeRuns.delete(sessionKey);
  return true;
}

/**
 * Run the agent using pi-coding-agent.
 * Sessions are cached per sessionKey for conversation continuity.
 */
export async function runAgent(opts: AgentRunOpts): Promise<AgentRunResult> {
  const baseUrl = opts.proxyUrl || process.env.NEBIUS_BASE_URL || "https://api.tokenfactory.nebius.com/v1/";
  const apiKey = opts.proxyKey || process.env.NEBIUS_API_KEY || "";
  const model = buildModel(opts.model, baseUrl, apiKey);
  const sessionKey = opts.sessionKey ?? "default";

  try {
    const session = await getOrCreateSession({
      sessionKey,
      workspaceDir: opts.workspaceDir,
      model,
      apiKey,
      chatSystemPrompt: opts.chatSystemPrompt,
      onSpawnWorker: opts.onSpawnWorker,
      onSendFile: opts.onSendFile,
    });

    // Collect assistant text from events for this prompt
    let fullText = "";

    const unsubscribe = session.subscribe((event: AgentSessionEvent) => {
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
        case "message_end": {
          const msg = event.message as unknown as { role?: string; content?: unknown };
          if (msg?.role === "assistant" && msg.content) {
            const content = msg.content;
            if (Array.isArray(content)) {
              for (const block of content) {
                if (block && typeof block === "object" && "type" in block && block.type === "text" && "text" in block) {
                  const t = String(block.text).trim();
                  if (t) fullText = t;
                }
              }
            } else if (typeof content === "string" && content.trim()) {
              fullText = content.trim();
            }
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

    // Track for abort
    activeRuns.set(sessionKey, { abort: () => session.abort() });
    try {
      await session.prompt(opts.prompt);
    } finally {
      activeRuns.delete(sessionKey);
    }
    unsubscribe();

    const payloads: ReplyPayload[] = [];
    if (fullText.trim()) {
      payloads.push({ text: fullText.trim() });
    }

    return { payloads };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    // If session errored, clear it so next message creates a fresh one
    sessionCache.delete(sessionKey);
    return {
      payloads: [{ text: `Ошибка: ${message}`, isError: true }],
      error: message,
    };
  }
}
