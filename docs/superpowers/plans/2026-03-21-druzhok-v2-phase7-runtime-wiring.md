# Druzhok v2 Phase 7: Runtime Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire pi-agent-core into the instance, connect the Telegram bot to the agent runtime, and add the memory file watcher — making Druzhok v2 a functional end-to-end system.

**Architecture:** The runtime wraps `createAgentSession` from `@mariozechner/pi-coding-agent` and subscribes to its `AssistantMessageEvent` stream. Events flow through the streaming coordinator and lane manager to Telegram's draft streams. The Grammy bot dispatches inbound messages to the runtime, which manages per-chat sessions. Memory file changes trigger re-indexing via `fs.watch`.

**Key API surface (from pi-mono):**
- `createAgentSession(opts)` → `{ session: AgentSession }` — creates the model loop
- `session.prompt(text, { images })` → runs the agent (model + tool loop)
- `streamSimple(model, context, opts)` → returns `AssistantMessageEventStream` with events: `text_delta`, `toolcall_start`, `toolcall_end`, `done`, `error`
- `Agent` subscribes via `session.on("agent_event", handler)` for streaming updates
- `SessionManager` persists transcripts as JSONL

**Tech Stack:** `@mariozechner/pi-agent-core`, `@mariozechner/pi-coding-agent`, `@mariozechner/pi-ai`, `grammy`, `vitest`

**Spec:** `docs/superpowers/specs/2026-03-21-druzhok-v2-design.md`

**Depends on:** Phases 1-6 (all existing packages)

---

## File Structure

```
packages/
├── core/src/
│   ├── runtime/
│   │   ├── agent-run.ts          # Wraps createAgentSession + prompt, emits events
│   │   ├── session-store.ts      # Per-chat session management (create/get/delete)
│   │   ├── system-prompt.ts      # Build per-run system prompt from AGENTS.md + chat config
│   │   └── run-dispatcher.ts     # Connects inbound messages → agent run → reply pipeline → channel
│   ├── memory/
│   │   ├── watcher.ts            # fs.watch on memory files, triggers re-index
│   │   └── memory-manager.ts     # Orchestrator: index on boot, search, re-index on change
│   └── instance.ts              # UPDATE: wire Grammy bot + runtime + memory watcher
├── telegram/src/
│   └── bot.ts                    # Grammy bot: long-polling, update dispatch to runtime
tests/
├── core/runtime/
│   ├── system-prompt.test.ts
│   ├── session-store.test.ts
│   └── run-dispatcher.test.ts
├── core/memory/
│   ├── watcher.test.ts
│   └── memory-manager.test.ts
├── telegram/
│   └── bot.test.ts
```

---

### Task 1: Install pi-agent Dependencies

**Files:**
- Modify: `packages/core/package.json`

- [ ] **Step 1: Add pi-agent dependencies to core package**

Add to `packages/core/package.json` dependencies:

```json
{
  "dependencies": {
    "@druzhok/shared": "workspace:*",
    "@mariozechner/pi-agent-core": "^0.61.0",
    "@mariozechner/pi-coding-agent": "^0.58.0",
    "@mariozechner/pi-ai": "^0.61.0"
  }
}
```

- [ ] **Step 2: Install**

Run (from druzhok-v2): `pnpm install`

- [ ] **Step 3: Verify build still passes**

Run: `pnpm build`

- [ ] **Step 4: Commit**

```bash
git commit -m "add pi-agent-core dependencies to core package"
```

---

### Task 2: System Prompt Builder

**Files:**
- Create: `packages/core/src/runtime/system-prompt.ts`
- Create: `tests/core/runtime/system-prompt.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
// tests/core/runtime/system-prompt.test.ts
import { describe, it, expect } from "vitest";
import { buildSystemPrompt, type SystemPromptContext } from "@druzhok/core/runtime/system-prompt.js";

describe("buildSystemPrompt", () => {
  const baseCtx: SystemPromptContext = {
    agentsMd: "# Druzhok\nYou are helpful.",
    chatSystemPrompt: undefined,
    skillsList: [],
    defaultModel: "openai/gpt-4o",
    workspaceDir: "/data/workspace",
  };

  it("includes AGENTS.md content", () => {
    const prompt = buildSystemPrompt(baseCtx);
    expect(prompt).toContain("You are helpful.");
  });

  it("includes current time", () => {
    const prompt = buildSystemPrompt(baseCtx);
    expect(prompt).toMatch(/Current time:/);
  });

  it("includes memory guidance", () => {
    const prompt = buildSystemPrompt(baseCtx);
    expect(prompt).toContain("MEMORY.md");
    expect(prompt).toContain("memory/");
  });

  it("appends per-chat system prompt", () => {
    const ctx = { ...baseCtx, chatSystemPrompt: "Be concise and technical." };
    const prompt = buildSystemPrompt(ctx);
    expect(prompt).toContain("Be concise and technical.");
  });

  it("includes skills list when present", () => {
    const ctx = {
      ...baseCtx,
      skillsList: [
        { name: "setup", description: "First-time setup" },
        { name: "debug", description: "Debug helper" },
      ],
    };
    const prompt = buildSystemPrompt(ctx);
    expect(prompt).toContain("setup");
    expect(prompt).toContain("debug");
  });

  it("handles missing AGENTS.md", () => {
    const ctx = { ...baseCtx, agentsMd: null };
    const prompt = buildSystemPrompt(ctx);
    expect(prompt).toBeTruthy();
    expect(prompt).toContain("MEMORY.md");
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement system-prompt.ts**

```ts
// packages/core/src/runtime/system-prompt.ts

export type SystemPromptContext = {
  agentsMd: string | null;
  chatSystemPrompt: string | undefined;
  skillsList: Array<{ name: string; description: string }>;
  defaultModel: string;
  workspaceDir: string;
};

export function buildSystemPrompt(ctx: SystemPromptContext): string {
  const sections: string[] = [];

  // Agent identity
  if (ctx.agentsMd) {
    sections.push(ctx.agentsMd);
  } else {
    sections.push("You are Druzhok, a personal AI assistant communicating via Telegram.");
  }

  // Memory guidance
  sections.push(`## Memory

- Write durable facts (preferences, decisions, reference info) to MEMORY.md
- Write daily notes and ephemeral context to memory/YYYY-MM-DD.md (use today's date)
- When someone says "remember this," write it down immediately
- Use memory_search to recall information from previous conversations`);

  // Skills
  if (ctx.skillsList.length > 0) {
    const skillLines = ctx.skillsList
      .map((s) => `- **${s.name}**: ${s.description}`)
      .join("\n");
    sections.push(`## Available Skills\n\n${skillLines}\n\nTo use a skill, read its SKILL.md file from the skills/ directory.`);
  }

  // Runtime info
  sections.push(`## Runtime

Current time: ${new Date().toISOString()}
Model: ${ctx.defaultModel}
Workspace: ${ctx.workspaceDir}`);

  // Per-chat overlay
  if (ctx.chatSystemPrompt) {
    sections.push(`## Chat-Specific Instructions\n\n${ctx.chatSystemPrompt}`);
  }

  return sections.join("\n\n");
}
```

- [ ] **Step 4: Run tests, verify pass**
- [ ] **Step 5: Commit**

```bash
git commit -m "add system prompt builder"
```

---

### Task 3: Session Store

**Files:**
- Create: `packages/core/src/runtime/session-store.ts`
- Create: `tests/core/runtime/session-store.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
// tests/core/runtime/session-store.test.ts
import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createSessionStore } from "@druzhok/core/runtime/session-store.js";

describe("createSessionStore", () => {
  let sessionsDir: string;

  beforeEach(() => {
    sessionsDir = mkdtempSync(join(tmpdir(), "druzhok-sessions-"));
  });
  afterEach(() => {
    rmSync(sessionsDir, { recursive: true, force: true });
  });

  it("creates new session for unknown key", () => {
    const store = createSessionStore(sessionsDir);
    const session = store.getOrCreate("telegram:dm:123");
    expect(session.sessionKey).toBe("telegram:dm:123");
    expect(session.sessionDir).toContain("telegram_dm_123");
  });

  it("returns same session for same key", () => {
    const store = createSessionStore(sessionsDir);
    const s1 = store.getOrCreate("telegram:dm:123");
    const s2 = store.getOrCreate("telegram:dm:123");
    expect(s1.sessionDir).toBe(s2.sessionDir);
  });

  it("creates different sessions for different keys", () => {
    const store = createSessionStore(sessionsDir);
    const s1 = store.getOrCreate("telegram:dm:123");
    const s2 = store.getOrCreate("telegram:group:456");
    expect(s1.sessionDir).not.toBe(s2.sessionDir);
  });

  it("deletes session", () => {
    const store = createSessionStore(sessionsDir);
    store.getOrCreate("telegram:dm:123");
    expect(store.has("telegram:dm:123")).toBe(true);
    store.delete("telegram:dm:123");
    expect(store.has("telegram:dm:123")).toBe(false);
  });

  it("lists active sessions", () => {
    const store = createSessionStore(sessionsDir);
    store.getOrCreate("telegram:dm:123");
    store.getOrCreate("telegram:group:456");
    expect(store.list()).toHaveLength(2);
  });
});
```

- [ ] **Step 2: Implement session-store.ts**

```ts
// packages/core/src/runtime/session-store.ts
import { mkdirSync, rmSync, existsSync } from "node:fs";
import { join } from "node:path";

export type SessionEntry = {
  sessionKey: string;
  sessionDir: string;
  createdAt: number;
};

export type SessionStore = {
  getOrCreate(sessionKey: string): SessionEntry;
  has(sessionKey: string): boolean;
  delete(sessionKey: string): void;
  list(): SessionEntry[];
};

function sanitizeKey(key: string): string {
  return key.replace(/[^a-zA-Z0-9_-]/g, "_");
}

export function createSessionStore(baseDir: string): SessionStore {
  const sessions = new Map<string, SessionEntry>();
  mkdirSync(baseDir, { recursive: true });

  return {
    getOrCreate(sessionKey: string): SessionEntry {
      let entry = sessions.get(sessionKey);
      if (entry) return entry;

      const dirName = sanitizeKey(sessionKey);
      const sessionDir = join(baseDir, dirName);
      mkdirSync(sessionDir, { recursive: true });

      entry = { sessionKey, sessionDir, createdAt: Date.now() };
      sessions.set(sessionKey, entry);
      return entry;
    },

    has(sessionKey: string): boolean {
      return sessions.has(sessionKey);
    },

    delete(sessionKey: string): void {
      const entry = sessions.get(sessionKey);
      if (entry) {
        if (existsSync(entry.sessionDir)) {
          rmSync(entry.sessionDir, { recursive: true, force: true });
        }
        sessions.delete(sessionKey);
      }
    },

    list(): SessionEntry[] {
      return [...sessions.values()];
    },
  };
}
```

- [ ] **Step 3: Run tests, verify pass**
- [ ] **Step 4: Commit**

```bash
git commit -m "add per-chat session store"
```

---

### Task 4: Agent Run Wrapper

**Files:**
- Create: `packages/core/src/runtime/agent-run.ts`

This wraps `createAgentSession` from pi-coding-agent and connects streaming events to our `StreamingCoordinator` and `LaneManager`. Since pi-agent-core manages the model loop internally, we subscribe to events rather than driving the loop ourselves.

NOTE: This file uses pi-agent-core APIs that may need adjustment once we test against real providers. The types are based on the pi-mono source code analysis. Mark any uncertainty with TODO comments.

- [ ] **Step 1: Implement agent-run.ts**

```ts
// packages/core/src/runtime/agent-run.ts
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

/**
 * Run the agent for a single user message.
 *
 * Uses @mariozechner/pi-coding-agent's createAgentSession to set up the
 * model loop. The agent handles tool calls internally; we subscribe to
 * streaming events for real-time delivery.
 *
 * TODO: This is a scaffold. The actual pi-coding-agent integration requires:
 * 1. Installing the packages and verifying API compatibility
 * 2. Configuring the model to use our proxy as an OpenAI-compatible endpoint
 * 3. Setting up tool definitions (exec, read, write, edit, memory_search, memory_get, message)
 * 4. Subscribing to AgentSession events for streaming
 * 5. Extracting final payloads from the completed run
 *
 * For now, this module defines the interface that the run-dispatcher will use.
 * The implementation will be filled in during the first integration test with a real provider.
 */
export async function runAgent(opts: AgentRunOpts): Promise<AgentRunResult> {
  const systemPrompt = buildSystemPrompt(opts.systemPromptCtx);

  // TODO: Replace with actual pi-coding-agent integration
  // The flow will be:
  //
  // 1. Create or reuse AgentSession:
  //    const { session } = await createAgentSession({
  //      cwd: opts.sessionDir,
  //      model: getModel(provider, modelId),  // from pi-ai
  //      tools: [...builtinTools],
  //    });
  //
  // 2. Subscribe to events:
  //    session.on("agent_event", (event) => {
  //      if (event.type === "text_delta") opts.onTextDelta?.(event.delta, false);
  //      if (event.type === "thinking_delta") opts.onTextDelta?.(event.delta, true);
  //      if (event.type === "toolcall_start") opts.onToolCallStart?.();
  //      if (event.type === "toolcall_end") opts.onToolCallEnd?.();
  //    });
  //
  // 3. Run the prompt:
  //    await session.prompt(opts.prompt);
  //
  // 4. Collect result:
  //    const result = session.getLastAssistantMessage();
  //    return { payloads: [{ text: result.content }] };

  // Placeholder: echo the prompt back (will be replaced)
  const payloads: ReplyPayload[] = [
    { text: `[Agent not yet connected] Received: ${opts.prompt.slice(0, 100)}` },
  ];

  return { payloads };
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `pnpm build`

- [ ] **Step 3: Commit**

```bash
git commit -m "add agent run wrapper (scaffold for pi-agent-core integration)"
```

---

### Task 5: Run Dispatcher

**Files:**
- Create: `packages/core/src/runtime/run-dispatcher.ts`
- Create: `tests/core/runtime/run-dispatcher.test.ts`

The dispatcher connects: inbound message → skill matching → agent run → reply pipeline → channel delivery.

- [ ] **Step 1: Write failing tests**

```ts
// tests/core/runtime/run-dispatcher.test.ts
import { describe, it, expect, vi } from "vitest";
import { createRunDispatcher } from "@druzhok/core/runtime/run-dispatcher.js";
import type { InboundContext, ReplyPayload, DeliveryResult, DraftStream, Channel } from "@druzhok/shared";

function mockChannel(): Channel {
  return {
    start: vi.fn().mockResolvedValue(undefined),
    stop: vi.fn().mockResolvedValue(undefined),
    onMessage: vi.fn().mockResolvedValue(undefined),
    sendMessage: vi.fn().mockResolvedValue({ delivered: true, messageId: 1 }),
    editMessage: vi.fn().mockResolvedValue(undefined),
    deleteMessage: vi.fn().mockResolvedValue(undefined),
    createDraftStream: vi.fn().mockReturnValue({
      update: vi.fn(),
      materialize: vi.fn().mockResolvedValue(1),
      forceNewMessage: vi.fn(),
      stop: vi.fn().mockResolvedValue(undefined),
      flush: vi.fn().mockResolvedValue(undefined),
      messageId: vi.fn().mockReturnValue(undefined),
    }),
    sendTyping: vi.fn().mockResolvedValue(undefined),
    setReaction: vi.fn().mockResolvedValue(undefined),
  };
}

function baseContext(): InboundContext {
  return {
    body: "Hello bot",
    from: "telegram:dm:123",
    chatId: "123",
    chatType: "direct",
    senderId: "456",
    senderName: "Igor",
    messageId: 42,
    sessionKey: "telegram:dm:456",
    timestamp: Date.now(),
  };
}

describe("createRunDispatcher", () => {
  it("dispatches message and delivers response", async () => {
    const channel = mockChannel();
    const dispatcher = createRunDispatcher({
      channel,
      runAgent: async () => ({ payloads: [{ text: "Hello!" }] }),
      config: {
        proxyUrl: "http://proxy:8080",
        proxyKey: "key",
        defaultModel: "openai/gpt-4o",
        workspaceDir: "/tmp/workspace",
        chats: {},
      },
      agentsMd: "You are helpful.",
      skillsList: [],
    });

    await dispatcher.dispatch(baseContext());
    expect(channel.sendMessage).toHaveBeenCalledWith(
      "123",
      expect.objectContaining({ text: "Hello!" }),
    );
  });

  it("sends typing indicator before run", async () => {
    const channel = mockChannel();
    const dispatcher = createRunDispatcher({
      channel,
      runAgent: async () => ({ payloads: [{ text: "response" }] }),
      config: { proxyUrl: "", proxyKey: "", defaultModel: "", workspaceDir: "/tmp", chats: {} },
      agentsMd: null,
      skillsList: [],
    });

    await dispatcher.dispatch(baseContext());
    expect(channel.sendTyping).toHaveBeenCalledWith("123");
  });

  it("filters NO_REPLY responses", async () => {
    const channel = mockChannel();
    const dispatcher = createRunDispatcher({
      channel,
      runAgent: async () => ({ payloads: [{ text: "NO_REPLY" }] }),
      config: { proxyUrl: "", proxyKey: "", defaultModel: "", workspaceDir: "/tmp", chats: {} },
      agentsMd: null,
      skillsList: [],
    });

    await dispatcher.dispatch(baseContext());
    expect(channel.sendMessage).not.toHaveBeenCalled();
  });

  it("delivers error payload on agent failure", async () => {
    const channel = mockChannel();
    const dispatcher = createRunDispatcher({
      channel,
      runAgent: async () => { throw new Error("Provider down"); },
      config: { proxyUrl: "", proxyKey: "", defaultModel: "", workspaceDir: "/tmp", chats: {} },
      agentsMd: null,
      skillsList: [],
    });

    await dispatcher.dispatch(baseContext());
    expect(channel.sendMessage).toHaveBeenCalledWith(
      "123",
      expect.objectContaining({ isError: true }),
    );
  });

  it("applies per-chat model override", async () => {
    const channel = mockChannel();
    let capturedModel = "";
    const dispatcher = createRunDispatcher({
      channel,
      runAgent: async (opts) => { capturedModel = opts.model; return { payloads: [{ text: "ok" }] }; },
      config: {
        proxyUrl: "", proxyKey: "", defaultModel: "openai/gpt-4o", workspaceDir: "/tmp",
        chats: { "telegram:dm:456": { model: "anthropic/claude-sonnet-4-20250514" } },
      },
      agentsMd: null,
      skillsList: [],
    });

    await dispatcher.dispatch(baseContext());
    expect(capturedModel).toBe("anthropic/claude-sonnet-4-20250514");
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement run-dispatcher.ts**

```ts
// packages/core/src/runtime/run-dispatcher.ts
import type { InboundContext, ReplyPayload, Channel } from "@druzhok/shared";
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
  agentsMd: string | null;
  skillsList: Array<{ name: string; description: string }>;
};

export type RunDispatcher = {
  dispatch(ctx: InboundContext): Promise<void>;
};

export function createRunDispatcher(opts: RunDispatcherOpts): RunDispatcher {
  const { channel, runAgent, config, agentsMd, skillsList } = opts;

  return {
    async dispatch(ctx: InboundContext): Promise<void> {
      // Send typing indicator
      await channel.sendTyping(ctx.chatId).catch(() => {});

      // Resolve per-chat overrides
      const chatConfig = config.chats[ctx.sessionKey];
      const model = chatConfig?.model ?? config.defaultModel;
      const chatSystemPrompt = chatConfig?.systemPrompt;

      try {
        const result = await runAgent({
          prompt: ctx.body,
          systemPromptCtx: {
            agentsMd,
            chatSystemPrompt,
            skillsList,
            defaultModel: model,
            workspaceDir: config.workspaceDir,
          },
          sessionDir: config.workspaceDir,
          proxyUrl: config.proxyUrl,
          proxyKey: config.proxyKey,
          model,
        });

        // Process through reply pipeline
        const filtered = processReplyPayloads(result.payloads, {
          showReasoning: false,
          sentTexts: [],
          isHeartbeat: false,
        });

        // Deliver each filtered payload
        for (const payload of filtered) {
          await channel.sendMessage(ctx.chatId, payload);
        }
      } catch (err) {
        const errorMessage = err instanceof Error ? err.message : String(err);
        await channel.sendMessage(ctx.chatId, {
          text: `Sorry, I encountered an error: ${errorMessage}`,
          isError: true,
        });
      }
    },
  };
}
```

- [ ] **Step 4: Run tests, verify pass**
- [ ] **Step 5: Commit**

```bash
git commit -m "add run dispatcher connecting messages to agent and channel"
```

---

### Task 6: Grammy Bot

**Files:**
- Create: `packages/telegram/src/bot.ts`
- Create: `tests/telegram/bot.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
// tests/telegram/bot.test.ts
import { describe, it, expect, vi } from "vitest";
import { classifyUpdate, type UpdateClassification } from "@druzhok/telegram/bot.js";

describe("classifyUpdate", () => {
  it("classifies text message", () => {
    const update = {
      message: {
        message_id: 1,
        date: Date.now() / 1000,
        chat: { id: 123, type: "private" as const },
        from: { id: 456, first_name: "Igor", is_bot: false },
        text: "Hello",
      },
    };
    expect(classifyUpdate(update)).toBe("message");
  });

  it("classifies command", () => {
    const update = {
      message: {
        message_id: 1,
        date: Date.now() / 1000,
        chat: { id: 123, type: "private" as const },
        from: { id: 456, first_name: "Igor", is_bot: false },
        text: "/start",
      },
    };
    expect(classifyUpdate(update)).toBe("command");
  });

  it("classifies photo message", () => {
    const update = {
      message: {
        message_id: 1,
        date: Date.now() / 1000,
        chat: { id: 123, type: "private" as const },
        from: { id: 456, first_name: "Igor", is_bot: false },
        photo: [{ file_id: "abc", file_unique_id: "def", width: 100, height: 100 }],
        caption: "Look at this",
      },
    };
    expect(classifyUpdate(update)).toBe("message");
  });

  it("ignores bot messages", () => {
    const update = {
      message: {
        message_id: 1,
        date: Date.now() / 1000,
        chat: { id: 123, type: "private" as const },
        from: { id: 456, first_name: "Bot", is_bot: true },
        text: "I am a bot",
      },
    };
    expect(classifyUpdate(update)).toBe("ignore");
  });

  it("ignores updates without message", () => {
    const update = {};
    expect(classifyUpdate(update)).toBe("ignore");
  });

  it("classifies unknown commands as message", () => {
    const update = {
      message: {
        message_id: 1,
        date: Date.now() / 1000,
        chat: { id: 123, type: "private" as const },
        from: { id: 456, first_name: "Igor", is_bot: false },
        text: "/unknown_command",
      },
    };
    // Unknown commands are treated as regular messages
    expect(classifyUpdate(update)).toBe("message");
  });
});
```

- [ ] **Step 2: Implement bot.ts**

```ts
// packages/telegram/src/bot.ts
import { parseCommand } from "./commands.js";

type TelegramUpdate = {
  message?: {
    message_id: number;
    date: number;
    chat: { id: number; type: string };
    from?: { id: number; first_name: string; is_bot: boolean };
    text?: string;
    caption?: string;
    photo?: unknown[];
    voice?: unknown;
    document?: unknown;
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

  // Has some content (text, photo, voice, document)
  if (text || msg.photo || msg.voice || msg.document) return "message";

  return "ignore";
}
```

- [ ] **Step 3: Run tests, verify pass**
- [ ] **Step 4: Commit**

```bash
git commit -m "add Grammy bot update classification"
```

---

### Task 7: Memory File Watcher

**Files:**
- Create: `packages/core/src/memory/watcher.ts`
- Create: `tests/core/memory/watcher.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
// tests/core/memory/watcher.test.ts
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createMemoryWatcher } from "@druzhok/core/memory/watcher.js";

describe("createMemoryWatcher", () => {
  let workspace: string;

  beforeEach(() => {
    workspace = mkdtempSync(join(tmpdir(), "druzhok-watch-"));
    mkdirSync(join(workspace, "memory"), { recursive: true });
  });

  afterEach(() => {
    rmSync(workspace, { recursive: true, force: true });
  });

  it("calls onChange when a memory file is modified", async () => {
    const onChange = vi.fn();
    const watcher = createMemoryWatcher(workspace, { onChange, debounceMs: 50 });
    watcher.start();

    writeFileSync(join(workspace, "MEMORY.md"), "new fact");
    await new Promise((r) => setTimeout(r, 200));

    expect(onChange).toHaveBeenCalled();
    watcher.stop();
  });

  it("debounces rapid changes", async () => {
    const onChange = vi.fn();
    const watcher = createMemoryWatcher(workspace, { onChange, debounceMs: 100 });
    watcher.start();

    writeFileSync(join(workspace, "MEMORY.md"), "fact 1");
    writeFileSync(join(workspace, "MEMORY.md"), "fact 2");
    writeFileSync(join(workspace, "MEMORY.md"), "fact 3");
    await new Promise((r) => setTimeout(r, 300));

    // Should have been called once or twice, not three times
    expect(onChange.mock.calls.length).toBeLessThanOrEqual(2);
    watcher.stop();
  });

  it("stop prevents further callbacks", async () => {
    const onChange = vi.fn();
    const watcher = createMemoryWatcher(workspace, { onChange, debounceMs: 50 });
    watcher.start();
    watcher.stop();

    writeFileSync(join(workspace, "MEMORY.md"), "after stop");
    await new Promise((r) => setTimeout(r, 200));

    expect(onChange).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Implement watcher.ts**

```ts
// packages/core/src/memory/watcher.ts
import { watch, type FSWatcher } from "node:fs";
import { join } from "node:path";
import { existsSync } from "node:fs";

export type MemoryWatcherOpts = {
  onChange: () => void;
  debounceMs?: number;
};

export type MemoryWatcher = {
  start(): void;
  stop(): void;
};

export function createMemoryWatcher(
  workspace: string,
  opts: MemoryWatcherOpts
): MemoryWatcher {
  const debounceMs = opts.debounceMs ?? 1500;
  const watchers: FSWatcher[] = [];
  let debounceTimer: ReturnType<typeof setTimeout> | null = null;
  let stopped = false;

  const triggerChange = () => {
    if (stopped) return;
    if (debounceTimer) clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => {
      if (!stopped) opts.onChange();
    }, debounceMs);
  };

  return {
    start() {
      // Watch MEMORY.md
      const memoryMd = join(workspace, "MEMORY.md");
      if (existsSync(memoryMd)) {
        try {
          watchers.push(watch(memoryMd, triggerChange));
        } catch { /* ignore */ }
      }

      // Watch memory/ directory
      const memoryDir = join(workspace, "memory");
      if (existsSync(memoryDir)) {
        try {
          watchers.push(watch(memoryDir, { recursive: true }, triggerChange));
        } catch { /* ignore */ }
      }
    },

    stop() {
      stopped = true;
      if (debounceTimer) clearTimeout(debounceTimer);
      for (const w of watchers) {
        try { w.close(); } catch { /* ignore */ }
      }
      watchers.length = 0;
    },
  };
}
```

- [ ] **Step 3: Run tests, verify pass**
- [ ] **Step 4: Commit**

```bash
git commit -m "add memory file watcher with debouncing"
```

---

### Task 8: Module Exports & Full Verification

**Files:**
- Modify: `packages/core/src/index.ts`
- Modify: `packages/telegram/src/index.ts`

- [ ] **Step 1: Add runtime and watcher exports to core**

Append to `packages/core/src/index.ts`:

```ts
export * from "./runtime/system-prompt.js";
export * from "./runtime/session-store.js";
export * from "./runtime/agent-run.js";
export * from "./runtime/run-dispatcher.js";
export * from "./memory/watcher.js";
```

- [ ] **Step 2: Add bot export to telegram**

Append to `packages/telegram/src/index.ts`:

```ts
export { classifyUpdate, type UpdateClassification } from "./bot.js";
```

- [ ] **Step 3: Build all packages**

Run: `pnpm build`
Expected: Clean build

- [ ] **Step 4: Run full test suite**

Run: `pnpm test`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git commit -m "export runtime and watcher modules"
```

---

## Phase 7 Complete Checklist

- [ ] pi-agent-core dependencies installed in core package
- [ ] System prompt builder assembles AGENTS.md + memory guidance + skills + chat overlay
- [ ] Session store manages per-chat session directories (create/get/delete)
- [ ] Agent run wrapper defines the interface for pi-agent-core integration (scaffold)
- [ ] Run dispatcher connects inbound → agent → pipeline → channel
- [ ] Grammy bot classifies updates (command/message/ignore)
- [ ] Memory watcher triggers re-index on file changes (debounced)
- [ ] `pnpm build` succeeds
- [ ] `pnpm test` all pass

## What Remains After Phase 7

The system is fully wired but the agent run is a scaffold (returns placeholder text). To make it functional:

1. **Fill in `agent-run.ts`** with actual `createAgentSession` + `session.prompt()` calls
2. **Register tools** (exec, read, write, edit, memory_search, memory_get, message)
3. **Test against a real provider** through the proxy
4. **Add Grammy bot startup** with long-polling and update dispatch to run-dispatcher

These are integration tasks that require a running proxy with real API keys. They can't be TDD'd in isolation — they need manual testing with `docker-compose up`.
