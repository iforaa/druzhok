# Druzhok v2 Phase 2: Telegram Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the Telegram channel as the first pluggable channel — bot setup, message handling, commands, draft streaming, markdown→HTML conversion, message chunking, and media download.

**Architecture:** The `@druzhok/telegram` package implements the `Channel` interface defined in the spec. It uses `grammy` for Telegram Bot API interaction. The channel interface is defined in `@druzhok/shared` (added in this phase). The runtime (Phase 3+) will call channel methods; for now we test the channel in isolation.

**Tech Stack:** `grammy@1.41.1`, `@druzhok/shared`, `@druzhok/core`, `vitest`

**Spec:** `docs/superpowers/specs/2026-03-21-druzhok-v2-design.md` — sections "Channel Interface" and "Telegram Implementation"

**Depends on:** Phase 1 (monorepo, shared types, core session keys)

---

## File Structure

```
packages/
├── shared/src/
│   ├── types.ts                          # ADD: Channel, DraftStream interfaces
│   └── ...
├── telegram/
│   ├── package.json
│   ├── tsconfig.json
│   └── src/
│       ├── index.ts                      # barrel export
│       ├── bot.ts                        # Grammy bot setup, long-polling, update dispatch
│       ├── context.ts                    # InboundContext builder from Grammy update
│       ├── commands.ts                   # /start, /stop, /reset, /model, /prompt handlers
│       ├── delivery.ts                   # sendMessage, editMessage, deleteMessage
│       ├── draft-stream.ts              # Streaming message edits with rate limiting
│       ├── format.ts                     # Markdown → Telegram HTML conversion
│       └── media.ts                      # Photo/voice/document download to workspace
tests/
├── telegram/
│   ├── context.test.ts
│   ├── commands.test.ts
│   ├── draft-stream.test.ts
│   ├── format.test.ts
│   └── delivery.test.ts
```

---

### Task 1: Add Channel Interface to Shared Types

**Files:**
- Modify: `packages/shared/src/types.ts`
- Create: `tests/shared/channel-interface.test.ts`

- [ ] **Step 1: Write failing test for Channel interface**

```ts
// tests/shared/channel-interface.test.ts
import { describe, it, expect } from "vitest";
import type { Channel, DraftStream, DraftStreamOpts, ReplyPayload, InboundContext, DeliveryResult } from "@druzhok/shared";

describe("Channel interface", () => {
  it("can be implemented as a mock", () => {
    const mockStream: DraftStream = {
      update: () => {},
      materialize: async () => 1,
      forceNewMessage: () => {},
      stop: async () => {},
      flush: async () => {},
      messageId: () => undefined,
    };

    const channel: Channel = {
      start: async () => {},
      stop: async () => {},
      onMessage: async () => {},
      sendMessage: async () => ({ delivered: true, messageId: 1 }),
      editMessage: async () => {},
      deleteMessage: async () => {},
      createDraftStream: () => mockStream,
      sendTyping: async () => {},
      setReaction: async () => {},
    };

    expect(channel).toBeDefined();
    expect(channel.createDraftStream("123", {})).toBe(mockStream);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd druzhok-v2 && pnpm test -- tests/shared/channel-interface.test.ts`
Expected: FAIL — Channel type not exported

- [ ] **Step 3: Add Channel and DraftStream interfaces to types.ts**

Add the following to the end of `packages/shared/src/types.ts`:

```ts
export interface DraftStream {
  update(text: string): void;
  materialize(): Promise<number>;
  forceNewMessage(): void;
  stop(): Promise<void>;
  flush(): Promise<void>;
  messageId(): number | undefined;
}

export interface Channel {
  start(): Promise<void>;
  stop(): Promise<void>;
  onMessage: (ctx: InboundContext) => Promise<void>;
  sendMessage(chatId: string, payload: ReplyPayload): Promise<DeliveryResult>;
  editMessage(chatId: string, messageId: number, payload: ReplyPayload): Promise<void>;
  deleteMessage(chatId: string, messageId: number): Promise<void>;
  createDraftStream(chatId: string, opts: DraftStreamOpts): DraftStream;
  sendTyping(chatId: string): Promise<void>;
  setReaction(chatId: string, messageId: number, emoji: string): Promise<void>;
}
```

- [ ] **Step 4: Run test**

Run: `cd druzhok-v2 && pnpm test -- tests/shared/channel-interface.test.ts`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add packages/shared/src/types.ts tests/shared/channel-interface.test.ts
git commit -m "add Channel and DraftStream interfaces to shared types"
```

---

### Task 2: Telegram Package Scaffolding

**Files:**
- Create: `packages/telegram/package.json`
- Create: `packages/telegram/tsconfig.json`
- Create: `packages/telegram/src/index.ts`
- Modify: `tsconfig.build.json` (add telegram reference)

- [ ] **Step 1: Create packages/telegram/package.json**

```json
{
  "name": "@druzhok/telegram",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "exports": {
    ".": "./dist/index.js",
    "./*": "./dist/*.js"
  },
  "scripts": {
    "build": "tsc"
  },
  "dependencies": {
    "@druzhok/shared": "workspace:*",
    "@druzhok/core": "workspace:*",
    "grammy": "^1.41.0"
  }
}
```

- [ ] **Step 2: Create packages/telegram/tsconfig.json**

```json
{
  "extends": "../../tsconfig.json",
  "compilerOptions": {
    "outDir": "dist",
    "rootDir": "src",
    "composite": true
  },
  "include": ["src"],
  "references": [
    { "path": "../shared" },
    { "path": "../core" }
  ]
}
```

- [ ] **Step 3: Create empty packages/telegram/src/index.ts**

```ts
export {};
```

- [ ] **Step 4: Add telegram to tsconfig.build.json references**

Add `{ "path": "packages/telegram" }` to the references array in `tsconfig.build.json`.

- [ ] **Step 5: Add alias to vitest.config.ts**

Add `"@druzhok/telegram": path.resolve(__dirname, "packages/telegram/src")` to the resolve.alias map.

- [ ] **Step 6: Install and build**

Run: `cd druzhok-v2 && pnpm install && pnpm build`
Expected: Clean install and build

- [ ] **Step 7: Commit**

```bash
git add packages/telegram/ tsconfig.build.json vitest.config.ts pnpm-lock.yaml
git commit -m "scaffold telegram package with grammy dependency"
```

---

### Task 3: Markdown → Telegram HTML Conversion

**Files:**
- Create: `packages/telegram/src/format.ts`
- Create: `tests/telegram/format.test.ts`

- [ ] **Step 1: Write failing format tests**

```ts
// tests/telegram/format.test.ts
import { describe, it, expect } from "vitest";
import { markdownToTelegramHtml, chunkText } from "@druzhok/telegram/format.js";

describe("markdownToTelegramHtml", () => {
  it("converts bold", () => {
    expect(markdownToTelegramHtml("**hello**")).toBe("<b>hello</b>");
  });

  it("converts italic", () => {
    expect(markdownToTelegramHtml("*hello*")).toBe("<i>hello</i>");
  });

  it("converts inline code", () => {
    expect(markdownToTelegramHtml("`code`")).toBe("<code>code</code>");
  });

  it("converts code blocks", () => {
    expect(markdownToTelegramHtml("```js\nconst x = 1;\n```"))
      .toBe('<pre><code class="language-js">const x = 1;</code></pre>');
  });

  it("converts code blocks without language", () => {
    expect(markdownToTelegramHtml("```\nhello\n```"))
      .toBe("<pre><code>hello</code></pre>");
  });

  it("converts links", () => {
    expect(markdownToTelegramHtml("[click](https://example.com)"))
      .toBe('<a href="https://example.com">click</a>');
  });

  it("escapes HTML entities in plain text", () => {
    expect(markdownToTelegramHtml("a < b & c > d")).toBe("a &lt; b &amp; c &gt; d");
  });

  it("handles plain text unchanged", () => {
    expect(markdownToTelegramHtml("just text")).toBe("just text");
  });

  it("converts strikethrough", () => {
    expect(markdownToTelegramHtml("~~deleted~~")).toBe("<s>deleted</s>");
  });
});

describe("chunkText", () => {
  it("returns single chunk for short text", () => {
    const chunks = chunkText("hello", 4096);
    expect(chunks).toEqual(["hello"]);
  });

  it("splits at newline boundary when possible", () => {
    const line = "x".repeat(100);
    const text = `${line}\n${line}\n${line}`;
    const chunks = chunkText(text, 210);
    expect(chunks.length).toBe(2);
    expect(chunks[0]).toBe(`${line}\n${line}`);
    expect(chunks[1]).toBe(line);
  });

  it("hard splits when no newline found", () => {
    const text = "x".repeat(200);
    const chunks = chunkText(text, 100);
    expect(chunks.length).toBe(2);
    expect(chunks[0].length).toBe(100);
    expect(chunks[1].length).toBe(100);
  });

  it("returns empty array for empty string", () => {
    expect(chunkText("", 4096)).toEqual([]);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd druzhok-v2 && pnpm test -- tests/telegram/format.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement format.ts**

```ts
// packages/telegram/src/format.ts

function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

export function markdownToTelegramHtml(md: string): string {
  let result = md;

  // Code blocks (must be first to prevent inner formatting)
  result = result.replace(
    /```(\w+)?\n([\s\S]*?)```/g,
    (_, lang, code) => {
      const escaped = escapeHtml(code.replace(/\n$/, ""));
      return lang
        ? `<pre><code class="language-${lang}">${escaped}</code></pre>`
        : `<pre><code>${escaped}</code></pre>`;
    }
  );

  // Inline code (before other inline formatting)
  result = result.replace(/`([^`]+)`/g, (_, code) => `<code>${escapeHtml(code)}</code>`);

  // Bold
  result = result.replace(/\*\*(.+?)\*\*/g, "<b>$1</b>");

  // Strikethrough
  result = result.replace(/~~(.+?)~~/g, "<s>$1</s>");

  // Italic (single *, must not match inside bold)
  result = result.replace(/(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)/g, "<i>$1</i>");

  // Links
  result = result.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2">$1</a>');

  // Escape remaining HTML entities (only in non-tag text)
  // We need to escape only text that isn't already inside HTML tags
  result = result.replace(/(?<=>|^)([^<]+)(?=<|$)/g, (match) => {
    // Don't re-escape already-processed content
    if (match.includes("&amp;") || match.includes("&lt;") || match.includes("&gt;")) {
      return match;
    }
    return escapeHtml(match);
  });

  return result;
}

export function chunkText(text: string, maxLength: number): string[] {
  if (!text) return [];
  if (text.length <= maxLength) return [text];

  const chunks: string[] = [];
  let remaining = text;

  while (remaining.length > 0) {
    if (remaining.length <= maxLength) {
      chunks.push(remaining);
      break;
    }

    // Try to split at a newline within the limit
    const slice = remaining.slice(0, maxLength);
    const lastNewline = slice.lastIndexOf("\n");

    if (lastNewline > 0) {
      chunks.push(remaining.slice(0, lastNewline));
      remaining = remaining.slice(lastNewline + 1);
    } else {
      // Hard split
      chunks.push(remaining.slice(0, maxLength));
      remaining = remaining.slice(maxLength);
    }
  }

  return chunks;
}
```

- [ ] **Step 4: Run tests**

Run: `cd druzhok-v2 && pnpm test -- tests/telegram/format.test.ts`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add packages/telegram/src/format.ts tests/telegram/format.test.ts
git commit -m "add markdown to Telegram HTML conversion and text chunking"
```

---

### Task 4: Draft Stream (Streaming Message Edits)

**Files:**
- Create: `packages/telegram/src/draft-stream.ts`
- Create: `tests/telegram/draft-stream.test.ts`

- [ ] **Step 1: Write failing draft stream tests**

```ts
// tests/telegram/draft-stream.test.ts
import { describe, it, expect, vi, beforeEach } from "vitest";
import { createDraftStream } from "@druzhok/telegram/draft-stream.js";

describe("createDraftStream", () => {
  let mockSend: ReturnType<typeof vi.fn>;
  let mockEdit: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    vi.useFakeTimers();
    mockSend = vi.fn().mockResolvedValue(42);
    mockEdit = vi.fn().mockResolvedValue(undefined);
  });

  it("does not send until minInitialChars reached", () => {
    const stream = createDraftStream({
      send: mockSend,
      edit: mockEdit,
      minInitialChars: 30,
    });

    stream.update("Hi");
    vi.advanceTimersByTime(2000);
    expect(mockSend).not.toHaveBeenCalled();
  });

  it("sends first message once minInitialChars reached", async () => {
    const stream = createDraftStream({
      send: mockSend,
      edit: mockEdit,
      minInitialChars: 10,
    });

    stream.update("Hello, this is a long enough message");
    await stream.flush();
    expect(mockSend).toHaveBeenCalledWith("Hello, this is a long enough message");
  });

  it("edits subsequent updates instead of sending new messages", async () => {
    const stream = createDraftStream({
      send: mockSend,
      edit: mockEdit,
      minInitialChars: 5,
    });

    stream.update("Hello world");
    await stream.flush();
    expect(mockSend).toHaveBeenCalledTimes(1);

    stream.update("Hello world, more text");
    await stream.flush();
    expect(mockEdit).toHaveBeenCalledWith(42, "Hello world, more text");
  });

  it("skips shorter text (anti-flicker)", async () => {
    const stream = createDraftStream({
      send: mockSend,
      edit: mockEdit,
      minInitialChars: 5,
    });

    stream.update("Hello world!");
    await stream.flush();
    stream.update("Hello world");  // shorter — skip
    await stream.flush();
    expect(mockEdit).not.toHaveBeenCalled();
  });

  it("messageId returns undefined before first send", () => {
    const stream = createDraftStream({
      send: mockSend,
      edit: mockEdit,
      minInitialChars: 30,
    });
    expect(stream.messageId()).toBeUndefined();
  });

  it("messageId returns id after first send", async () => {
    const stream = createDraftStream({
      send: mockSend,
      edit: mockEdit,
      minInitialChars: 5,
    });
    stream.update("Hello world");
    await stream.flush();
    expect(stream.messageId()).toBe(42);
  });

  it("materialize returns message id", async () => {
    const stream = createDraftStream({
      send: mockSend,
      edit: mockEdit,
      minInitialChars: 5,
    });
    stream.update("Hello world");
    await stream.flush();
    const id = await stream.materialize();
    expect(id).toBe(42);
  });

  it("forceNewMessage resets so next update sends a new message", async () => {
    const stream = createDraftStream({
      send: mockSend,
      edit: mockEdit,
      minInitialChars: 5,
    });

    stream.update("First message here");
    await stream.flush();
    expect(mockSend).toHaveBeenCalledTimes(1);

    stream.forceNewMessage();
    mockSend.mockResolvedValue(99);

    stream.update("Second message here");
    await stream.flush();
    expect(mockSend).toHaveBeenCalledTimes(2);
    expect(stream.messageId()).toBe(99);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd druzhok-v2 && pnpm test -- tests/telegram/draft-stream.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement draft-stream.ts**

```ts
// packages/telegram/src/draft-stream.ts
import type { DraftStream } from "@druzhok/shared";

export type DraftStreamDeps = {
  send: (text: string) => Promise<number>;
  edit: (messageId: number, text: string) => Promise<void>;
  minInitialChars?: number;
};

export function createDraftStream(deps: DraftStreamDeps): DraftStream {
  const minChars = deps.minInitialChars ?? 30;
  let currentMessageId: number | undefined;
  let lastText = "";
  let pendingText: string | null = null;
  let isStopped = false;

  return {
    update(text: string) {
      if (isStopped) return;
      // Anti-flicker: skip if new text is shorter than what we already showed
      if (lastText && text.length < lastText.length && lastText.startsWith(text)) {
        return;
      }
      pendingText = text;
    },

    async flush() {
      if (pendingText === null || isStopped) return;
      const text = pendingText;
      pendingText = null;

      if (currentMessageId === undefined) {
        // First message — wait for min chars
        if (text.length < minChars) return;
        currentMessageId = await deps.send(text);
        lastText = text;
      } else {
        // Subsequent — edit existing message
        if (text === lastText) return;
        await deps.edit(currentMessageId, text);
        lastText = text;
      }
    },

    async materialize() {
      await this.flush();
      return currentMessageId ?? 0;
    },

    forceNewMessage() {
      currentMessageId = undefined;
      lastText = "";
      pendingText = null;
    },

    async stop() {
      isStopped = true;
      await this.flush();
    },

    messageId() {
      return currentMessageId;
    },
  };
}
```

- [ ] **Step 4: Run tests**

Run: `cd druzhok-v2 && pnpm test -- tests/telegram/draft-stream.test.ts`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add packages/telegram/src/draft-stream.ts tests/telegram/draft-stream.test.ts
git commit -m "add draft stream with rate limiting and anti-flicker"
```

---

### Task 5: InboundContext Builder

**Files:**
- Create: `packages/telegram/src/context.ts`
- Create: `tests/telegram/context.test.ts`

- [ ] **Step 1: Write failing context tests**

```ts
// tests/telegram/context.test.ts
import { describe, it, expect } from "vitest";
import { buildInboundContext } from "@druzhok/telegram/context.js";

describe("buildInboundContext", () => {
  const baseUpdate = {
    message: {
      message_id: 42,
      date: 1711036800,
      chat: { id: 123, type: "private" as const },
      from: { id: 456, first_name: "Igor", is_bot: false },
      text: "Hello bot",
    },
  };

  it("builds DM context", () => {
    const ctx = buildInboundContext(baseUpdate);
    expect(ctx.body).toBe("Hello bot");
    expect(ctx.chatId).toBe("123");
    expect(ctx.chatType).toBe("direct");
    expect(ctx.senderId).toBe("456");
    expect(ctx.senderName).toBe("Igor");
    expect(ctx.messageId).toBe(42);
    expect(ctx.sessionKey).toBe("telegram:dm:456");
    expect(ctx.timestamp).toBe(1711036800000);
  });

  it("builds group context", () => {
    const update = {
      message: {
        ...baseUpdate.message,
        chat: { id: -789, type: "group" as const, title: "My Group" },
      },
    };
    const ctx = buildInboundContext(update);
    expect(ctx.chatType).toBe("group");
    expect(ctx.chatId).toBe("-789");
    expect(ctx.sessionKey).toBe("telegram:group:-789");
  });

  it("builds supergroup context", () => {
    const update = {
      message: {
        ...baseUpdate.message,
        chat: { id: -100789, type: "supergroup" as const, title: "Super" },
      },
    };
    const ctx = buildInboundContext(update);
    expect(ctx.chatType).toBe("group");
    expect(ctx.sessionKey).toBe("telegram:group:-100789");
  });

  it("builds forum topic context", () => {
    const update = {
      message: {
        ...baseUpdate.message,
        chat: { id: -100789, type: "supergroup" as const, title: "Forum", is_forum: true },
        message_thread_id: 7,
      },
    };
    const ctx = buildInboundContext(update);
    expect(ctx.sessionKey).toBe("telegram:group:-100789:topic:7");
  });

  it("builds reply context", () => {
    const update = {
      message: {
        ...baseUpdate.message,
        reply_to_message: {
          message_id: 40,
          date: 1711036700,
          chat: { id: 123, type: "private" as const },
          from: { id: 789, first_name: "Bot", is_bot: true },
          text: "Previous message",
        },
      },
    };
    const ctx = buildInboundContext(update);
    expect(ctx.replyTo).toBeDefined();
    expect(ctx.replyTo!.messageId).toBe(40);
    expect(ctx.replyTo!.body).toBe("Previous message");
    expect(ctx.replyTo!.senderName).toBe("Bot");
  });

  it("handles missing text (photo-only message)", () => {
    const update = {
      message: {
        ...baseUpdate.message,
        text: undefined,
        caption: "Photo caption",
      },
    };
    const ctx = buildInboundContext(update);
    expect(ctx.body).toBe("Photo caption");
  });

  it("handles fully empty message", () => {
    const update = {
      message: {
        ...baseUpdate.message,
        text: undefined,
      },
    };
    const ctx = buildInboundContext(update);
    expect(ctx.body).toBe("");
  });

  it("builds sender name from first + last name", () => {
    const update = {
      message: {
        ...baseUpdate.message,
        from: { id: 456, first_name: "Igor", last_name: "K", is_bot: false },
      },
    };
    const ctx = buildInboundContext(update);
    expect(ctx.senderName).toBe("Igor K");
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd druzhok-v2 && pnpm test -- tests/telegram/context.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement context.ts**

```ts
// packages/telegram/src/context.ts
import type { InboundContext, ReplyContext } from "@druzhok/shared";
import { buildSessionKey } from "@druzhok/core/session/session-key.js";

type TelegramChat = {
  id: number;
  type: "private" | "group" | "supergroup" | "channel";
  title?: string;
  is_forum?: boolean;
};

type TelegramUser = {
  id: number;
  first_name: string;
  last_name?: string;
  username?: string;
  is_bot: boolean;
};

type TelegramMessage = {
  message_id: number;
  date: number;
  chat: TelegramChat;
  from?: TelegramUser;
  text?: string;
  caption?: string;
  message_thread_id?: number;
  reply_to_message?: TelegramMessage;
};

type TelegramUpdate = {
  message: TelegramMessage;
};

function buildSenderName(user?: TelegramUser): string {
  if (!user) return "Unknown";
  const parts = [user.first_name];
  if (user.last_name) parts.push(user.last_name);
  return parts.join(" ");
}

function resolveChatType(chat: TelegramChat): "direct" | "group" {
  return chat.type === "private" ? "direct" : "group";
}

function resolveSessionKey(chat: TelegramChat, from?: TelegramUser, threadId?: number): string {
  const chatType = resolveChatType(chat);

  if (chatType === "direct") {
    return buildSessionKey({
      channel: "telegram",
      chatType: "direct",
      chatId: String(from?.id ?? chat.id),
    });
  }

  return buildSessionKey({
    channel: "telegram",
    chatType: "group",
    chatId: String(chat.id),
    topicId: chat.is_forum && threadId ? String(threadId) : undefined,
  });
}

function buildReplyContext(msg?: TelegramMessage): ReplyContext | undefined {
  if (!msg) return undefined;
  return {
    messageId: msg.message_id,
    senderId: String(msg.from?.id ?? 0),
    senderName: buildSenderName(msg.from),
    body: msg.text ?? msg.caption ?? "",
  };
}

export function buildInboundContext(update: TelegramUpdate): InboundContext {
  const msg = update.message;
  const chat = msg.chat;
  const from = msg.from;

  return {
    body: msg.text ?? msg.caption ?? "",
    from: `telegram:${resolveChatType(chat) === "direct" ? "dm" : "group"}:${chat.id}`,
    chatId: String(chat.id),
    chatType: resolveChatType(chat),
    senderId: String(from?.id ?? 0),
    senderName: buildSenderName(from),
    messageId: msg.message_id,
    replyTo: buildReplyContext(msg.reply_to_message),
    sessionKey: resolveSessionKey(chat, from, msg.message_thread_id),
    timestamp: msg.date * 1000,
  };
}
```

- [ ] **Step 4: Run tests**

Run: `cd druzhok-v2 && pnpm test -- tests/telegram/context.test.ts`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add packages/telegram/src/context.ts tests/telegram/context.test.ts
git commit -m "add Telegram inbound context builder"
```

---

### Task 6: Command Handling

**Files:**
- Create: `packages/telegram/src/commands.ts`
- Create: `tests/telegram/commands.test.ts`

- [ ] **Step 1: Write failing command tests**

```ts
// tests/telegram/commands.test.ts
import { describe, it, expect } from "vitest";
import { parseCommand, type ParsedCommand } from "@druzhok/telegram/commands.js";

describe("parseCommand", () => {
  it("parses /start", () => {
    expect(parseCommand("/start")).toEqual({ command: "start", args: "" });
  });

  it("parses /model with args", () => {
    expect(parseCommand("/model anthropic/claude-sonnet-4-20250514")).toEqual({
      command: "model",
      args: "anthropic/claude-sonnet-4-20250514",
    });
  });

  it("parses /prompt with multi-word args", () => {
    expect(parseCommand("/prompt You are a helpful assistant")).toEqual({
      command: "prompt",
      args: "You are a helpful assistant",
    });
  });

  it("parses /reset", () => {
    expect(parseCommand("/reset")).toEqual({ command: "reset", args: "" });
  });

  it("parses /stop", () => {
    expect(parseCommand("/stop")).toEqual({ command: "stop", args: "" });
  });

  it("returns null for non-command text", () => {
    expect(parseCommand("hello world")).toBeNull();
  });

  it("returns null for empty string", () => {
    expect(parseCommand("")).toBeNull();
  });

  it("strips bot username from command", () => {
    expect(parseCommand("/start@mybot")).toEqual({ command: "start", args: "" });
  });

  it("returns null for unknown commands", () => {
    expect(parseCommand("/unknown")).toBeNull();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd druzhok-v2 && pnpm test -- tests/telegram/commands.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement commands.ts**

```ts
// packages/telegram/src/commands.ts

const KNOWN_COMMANDS = new Set(["start", "stop", "reset", "prompt", "model"]);

export type ParsedCommand = {
  command: string;
  args: string;
};

export function parseCommand(text: string): ParsedCommand | null {
  if (!text || !text.startsWith("/")) return null;

  const parts = text.split(/\s+/);
  const commandPart = parts[0];

  // Strip @botname suffix
  const command = commandPart.slice(1).replace(/@\S+$/, "").toLowerCase();

  if (!KNOWN_COMMANDS.has(command)) return null;

  const args = parts.slice(1).join(" ").trim();
  return { command, args };
}
```

- [ ] **Step 4: Run tests**

Run: `cd druzhok-v2 && pnpm test -- tests/telegram/commands.test.ts`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add packages/telegram/src/commands.ts tests/telegram/commands.test.ts
git commit -m "add Telegram command parsing"
```

---

### Task 7: Message Delivery

**Files:**
- Create: `packages/telegram/src/delivery.ts`
- Create: `tests/telegram/delivery.test.ts`

- [ ] **Step 1: Write failing delivery tests**

```ts
// tests/telegram/delivery.test.ts
import { describe, it, expect, vi } from "vitest";
import { createDelivery, type TelegramApi } from "@druzhok/telegram/delivery.js";

describe("createDelivery", () => {
  const mockApi: TelegramApi = {
    sendMessage: vi.fn().mockResolvedValue({ message_id: 1 }),
    editMessageText: vi.fn().mockResolvedValue(undefined),
    deleteMessage: vi.fn().mockResolvedValue(true),
  };

  it("sends text message and returns delivery result", async () => {
    const delivery = createDelivery(mockApi);
    const result = await delivery.sendMessage("123", { text: "Hello" });
    expect(result.delivered).toBe(true);
    expect(result.messageId).toBe(1);
    expect(mockApi.sendMessage).toHaveBeenCalledWith(
      "123",
      expect.stringContaining("Hello"),
      expect.any(Object),
    );
  });

  it("chunks long messages", async () => {
    const delivery = createDelivery(mockApi);
    const longText = "x".repeat(5000);
    await delivery.sendMessage("123", { text: longText });
    // Should be called twice (4096 + remainder)
    expect(mockApi.sendMessage).toHaveBeenCalledTimes(2);
  });

  it("skips empty payload", async () => {
    const api: TelegramApi = {
      sendMessage: vi.fn(),
      editMessageText: vi.fn(),
      deleteMessage: vi.fn(),
    };
    const delivery = createDelivery(api);
    const result = await delivery.sendMessage("123", {});
    expect(result.delivered).toBe(false);
    expect(api.sendMessage).not.toHaveBeenCalled();
  });

  it("edits existing message", async () => {
    const delivery = createDelivery(mockApi);
    await delivery.editMessage("123", 42, { text: "Updated" });
    expect(mockApi.editMessageText).toHaveBeenCalledWith(
      "123",
      42,
      expect.stringContaining("Updated"),
      expect.any(Object),
    );
  });

  it("deletes message", async () => {
    const delivery = createDelivery(mockApi);
    await delivery.deleteMessage("123", 42);
    expect(mockApi.deleteMessage).toHaveBeenCalledWith("123", 42);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd druzhok-v2 && pnpm test -- tests/telegram/delivery.test.ts`
Expected: FAIL

- [ ] **Step 3: Implement delivery.ts**

```ts
// packages/telegram/src/delivery.ts
import type { ReplyPayload, DeliveryResult } from "@druzhok/shared";
import { markdownToTelegramHtml, chunkText } from "./format.js";

const TELEGRAM_MAX_LENGTH = 4096;

export type TelegramApi = {
  sendMessage(chatId: string, text: string, opts: Record<string, unknown>): Promise<{ message_id: number }>;
  editMessageText(chatId: string, messageId: number, text: string, opts: Record<string, unknown>): Promise<unknown>;
  deleteMessage(chatId: string, messageId: number): Promise<unknown>;
};

export type Delivery = {
  sendMessage(chatId: string, payload: ReplyPayload): Promise<DeliveryResult>;
  editMessage(chatId: string, messageId: number, payload: ReplyPayload): Promise<void>;
  deleteMessage(chatId: string, messageId: number): Promise<void>;
};

export function createDelivery(api: TelegramApi): Delivery {
  return {
    async sendMessage(chatId, payload) {
      const text = payload.text?.trim();
      if (!text) {
        return { delivered: false };
      }

      const html = markdownToTelegramHtml(text);
      const chunks = chunkText(html, TELEGRAM_MAX_LENGTH);

      let lastMessageId: number | undefined;
      for (const chunk of chunks) {
        const result = await api.sendMessage(chatId, chunk, { parse_mode: "HTML" });
        lastMessageId = result.message_id;
      }

      return { delivered: true, messageId: lastMessageId };
    },

    async editMessage(chatId, messageId, payload) {
      const text = payload.text?.trim();
      if (!text) return;

      const html = markdownToTelegramHtml(text);
      const truncated = html.slice(0, TELEGRAM_MAX_LENGTH);

      try {
        await api.editMessageText(chatId, messageId, truncated, { parse_mode: "HTML" });
      } catch (err) {
        // Silently ignore "message is not modified" errors
        const msg = err instanceof Error ? err.message : String(err);
        if (!msg.includes("not modified")) throw err;
      }
    },

    async deleteMessage(chatId, messageId) {
      await api.deleteMessage(chatId, messageId);
    },
  };
}
```

- [ ] **Step 4: Run tests**

Run: `cd druzhok-v2 && pnpm test -- tests/telegram/delivery.test.ts`
Expected: All PASS

- [ ] **Step 5: Commit**

```bash
git add packages/telegram/src/delivery.ts tests/telegram/delivery.test.ts
git commit -m "add Telegram message delivery with chunking"
```

---

### Task 8: Barrel Exports & Full Test Run

**Files:**
- Modify: `packages/telegram/src/index.ts`

- [ ] **Step 1: Update barrel export**

```ts
// packages/telegram/src/index.ts
export { markdownToTelegramHtml, chunkText } from "./format.js";
export { createDraftStream, type DraftStreamDeps } from "./draft-stream.js";
export { buildInboundContext } from "./context.js";
export { parseCommand, type ParsedCommand } from "./commands.js";
export { createDelivery, type TelegramApi, type Delivery } from "./delivery.js";
```

- [ ] **Step 2: Build all packages**

Run: `cd druzhok-v2 && pnpm build`
Expected: Clean build

- [ ] **Step 3: Run full test suite**

Run: `cd druzhok-v2 && pnpm test`
Expected: All tests pass (66 from Phase 1 + new telegram tests)

- [ ] **Step 4: Commit**

```bash
git add packages/telegram/src/index.ts
git commit -m "add telegram barrel exports"
```

---

## Phase 2 Complete Checklist

After all tasks are done, verify:

- [ ] `pnpm build` succeeds with no errors across all 4 packages
- [ ] `pnpm test` runs all tests and passes
- [ ] Channel interface is defined in shared types
- [ ] Telegram package has: format, draft-stream, context, commands, delivery
- [ ] All Telegram components are independently testable (no Grammy bot dependency in tests)
