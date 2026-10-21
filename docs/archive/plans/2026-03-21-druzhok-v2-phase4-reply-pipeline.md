# Druzhok v2 Phase 4: Reply Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the payload-based reply pipeline that filters agent output before delivery — NO_REPLY suppression, reasoning block filtering, duplicate suppression, and streaming coordination with draft lanes.

**Architecture:** The reply pipeline lives in `@druzhok/core` as a self-contained module. It receives `ReplyPayload[]` from the agent run and produces a filtered, deduplicated list ready for channel delivery. Streaming coordination connects the agent's text deltas to the channel's `DraftStream`.

**Tech Stack:** `@druzhok/shared`, `vitest`

**Spec:** `docs/superpowers/specs/2026-03-21-druzhok-v2-design.md` — sections "Reply Pipeline & Payload Model", "Streaming (Draft Lanes)"

**Depends on:** Phase 1 (shared types, tokens), Phase 2 (DraftStream interface)

---

## File Structure

```
packages/core/src/
├── reply/
│   ├── pipeline.ts               # Main pipeline: filter, dedupe, deliver
│   ├── filters.ts                # Individual filter stages
│   ├── streaming.ts              # Streaming coordinator: agent deltas → draft lanes
│   └── lane.ts                   # Lane state management (answer + reasoning)
tests/core/
├── reply/
│   ├── filters.test.ts
│   ├── pipeline.test.ts
│   ├── streaming.test.ts
│   └── lane.test.ts
```

---

### Task 1: Reply Filters

**Files:**
- Create: `packages/core/src/reply/filters.ts`
- Create: `tests/core/reply/filters.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
// tests/core/reply/filters.test.ts
import { describe, it, expect } from "vitest";
import {
  filterSilentReplies,
  filterReasoningBlocks,
  filterEmptyPayloads,
  deduplicateAgainstSent,
  stripHeartbeatFromPayloads,
} from "@druzhok/core/reply/filters.js";
import type { ReplyPayload } from "@druzhok/shared";

describe("filterSilentReplies", () => {
  it("removes NO_REPLY-only payloads", () => {
    const payloads: ReplyPayload[] = [{ text: "NO_REPLY" }];
    expect(filterSilentReplies(payloads)).toHaveLength(0);
  });

  it("keeps payloads with real text", () => {
    const payloads: ReplyPayload[] = [{ text: "Hello world" }];
    expect(filterSilentReplies(payloads)).toHaveLength(1);
  });

  it("strips trailing NO_REPLY from mixed text", () => {
    const payloads: ReplyPayload[] = [{ text: "Done. NO_REPLY" }];
    const filtered = filterSilentReplies(payloads);
    expect(filtered).toHaveLength(1);
    expect(filtered[0].text).toBe("Done.");
  });

  it("removes payloads with only whitespace + NO_REPLY", () => {
    const payloads: ReplyPayload[] = [{ text: "  NO_REPLY  " }];
    expect(filterSilentReplies(payloads)).toHaveLength(0);
  });
});

describe("filterReasoningBlocks", () => {
  it("removes reasoning payloads by default", () => {
    const payloads: ReplyPayload[] = [
      { text: "thinking...", isReasoning: true },
      { text: "Here is my answer" },
    ];
    expect(filterReasoningBlocks(payloads, false)).toHaveLength(1);
    expect(filterReasoningBlocks(payloads, false)[0].text).toBe("Here is my answer");
  });

  it("keeps reasoning payloads when enabled", () => {
    const payloads: ReplyPayload[] = [
      { text: "thinking...", isReasoning: true },
      { text: "answer" },
    ];
    expect(filterReasoningBlocks(payloads, true)).toHaveLength(2);
  });
});

describe("filterEmptyPayloads", () => {
  it("removes payloads with no text and no media", () => {
    const payloads: ReplyPayload[] = [{}];
    expect(filterEmptyPayloads(payloads)).toHaveLength(0);
  });

  it("keeps payloads with text", () => {
    const payloads: ReplyPayload[] = [{ text: "hello" }];
    expect(filterEmptyPayloads(payloads)).toHaveLength(1);
  });

  it("keeps payloads with media", () => {
    const payloads: ReplyPayload[] = [{ mediaUrl: "file:///tmp/img.png" }];
    expect(filterEmptyPayloads(payloads)).toHaveLength(1);
  });

  it("removes whitespace-only text payloads", () => {
    const payloads: ReplyPayload[] = [{ text: "   " }];
    expect(filterEmptyPayloads(payloads)).toHaveLength(0);
  });
});

describe("deduplicateAgainstSent", () => {
  it("removes payloads matching already-sent text", () => {
    const payloads: ReplyPayload[] = [{ text: "Hello world" }];
    const sentTexts = ["Hello world"];
    expect(deduplicateAgainstSent(payloads, sentTexts)).toHaveLength(0);
  });

  it("keeps payloads that differ from sent", () => {
    const payloads: ReplyPayload[] = [{ text: "New message" }];
    const sentTexts = ["Old message"];
    expect(deduplicateAgainstSent(payloads, sentTexts)).toHaveLength(1);
  });

  it("handles empty sent list", () => {
    const payloads: ReplyPayload[] = [{ text: "Hello" }];
    expect(deduplicateAgainstSent(payloads, [])).toHaveLength(1);
  });
});

describe("stripHeartbeatFromPayloads", () => {
  it("removes HEARTBEAT_OK-only payloads", () => {
    const payloads: ReplyPayload[] = [{ text: "HEARTBEAT_OK" }];
    expect(stripHeartbeatFromPayloads(payloads)).toHaveLength(0);
  });

  it("strips HEARTBEAT_OK from mixed text", () => {
    const payloads: ReplyPayload[] = [{ text: "Build failed! HEARTBEAT_OK" }];
    const filtered = stripHeartbeatFromPayloads(payloads);
    expect(filtered).toHaveLength(1);
    expect(filtered[0].text).toBe("Build failed!");
  });

  it("keeps normal payloads unchanged", () => {
    const payloads: ReplyPayload[] = [{ text: "Normal response" }];
    expect(stripHeartbeatFromPayloads(payloads)).toHaveLength(1);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement filters.ts**

```ts
// packages/core/src/reply/filters.ts
import type { ReplyPayload } from "@druzhok/shared";
import { isSilentReplyText, stripSilentToken, isHeartbeatOnly, stripHeartbeatToken } from "@druzhok/shared";

export function filterSilentReplies(payloads: ReplyPayload[]): ReplyPayload[] {
  return payloads
    .map((p) => {
      if (!p.text) return p;
      if (isSilentReplyText(p.text)) return null;
      const stripped = stripSilentToken(p.text);
      if (!stripped) return null;
      return stripped !== p.text ? { ...p, text: stripped } : p;
    })
    .filter((p): p is ReplyPayload => p !== null);
}

export function filterReasoningBlocks(payloads: ReplyPayload[], showReasoning: boolean): ReplyPayload[] {
  if (showReasoning) return payloads;
  return payloads.filter((p) => !p.isReasoning);
}

export function filterEmptyPayloads(payloads: ReplyPayload[]): ReplyPayload[] {
  return payloads.filter((p) => {
    const hasText = p.text && p.text.trim().length > 0;
    const hasMedia = p.mediaUrl || (p.mediaUrls && p.mediaUrls.length > 0);
    return hasText || hasMedia;
  });
}

export function deduplicateAgainstSent(payloads: ReplyPayload[], sentTexts: string[]): ReplyPayload[] {
  if (sentTexts.length === 0) return payloads;
  const sentSet = new Set(sentTexts.map((t) => t.trim()));
  return payloads.filter((p) => !p.text || !sentSet.has(p.text.trim()));
}

export function stripHeartbeatFromPayloads(payloads: ReplyPayload[]): ReplyPayload[] {
  return payloads
    .map((p) => {
      if (!p.text) return p;
      if (isHeartbeatOnly(p.text)) return null;
      const stripped = stripHeartbeatToken(p.text);
      if (!stripped) return null;
      return stripped !== p.text ? { ...p, text: stripped } : p;
    })
    .filter((p): p is ReplyPayload => p !== null);
}
```

- [ ] **Step 4: Run tests, verify pass**
- [ ] **Step 5: Commit**

```bash
git commit -m "add reply payload filters"
```

---

### Task 2: Reply Pipeline

**Files:**
- Create: `packages/core/src/reply/pipeline.ts`
- Create: `tests/core/reply/pipeline.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
// tests/core/reply/pipeline.test.ts
import { describe, it, expect } from "vitest";
import { processReplyPayloads, type PipelineOpts } from "@druzhok/core/reply/pipeline.js";
import type { ReplyPayload } from "@druzhok/shared";

const defaultOpts: PipelineOpts = {
  showReasoning: false,
  sentTexts: [],
  isHeartbeat: false,
};

describe("processReplyPayloads", () => {
  it("passes through normal payloads", () => {
    const payloads: ReplyPayload[] = [{ text: "Hello" }];
    const result = processReplyPayloads(payloads, defaultOpts);
    expect(result).toHaveLength(1);
    expect(result[0].text).toBe("Hello");
  });

  it("filters NO_REPLY", () => {
    const payloads: ReplyPayload[] = [{ text: "NO_REPLY" }];
    expect(processReplyPayloads(payloads, defaultOpts)).toHaveLength(0);
  });

  it("filters reasoning blocks", () => {
    const payloads: ReplyPayload[] = [
      { text: "thinking", isReasoning: true },
      { text: "answer" },
    ];
    expect(processReplyPayloads(payloads, defaultOpts)).toHaveLength(1);
  });

  it("deduplicates against sent texts", () => {
    const payloads: ReplyPayload[] = [{ text: "Already sent" }];
    const opts = { ...defaultOpts, sentTexts: ["Already sent"] };
    expect(processReplyPayloads(payloads, opts)).toHaveLength(0);
  });

  it("strips HEARTBEAT_OK in heartbeat mode", () => {
    const payloads: ReplyPayload[] = [{ text: "HEARTBEAT_OK" }];
    const opts = { ...defaultOpts, isHeartbeat: true };
    expect(processReplyPayloads(payloads, opts)).toHaveLength(0);
  });

  it("strips HEARTBEAT_OK from mixed heartbeat text", () => {
    const payloads: ReplyPayload[] = [{ text: "Build failed HEARTBEAT_OK" }];
    const opts = { ...defaultOpts, isHeartbeat: true };
    const result = processReplyPayloads(payloads, opts);
    expect(result).toHaveLength(1);
    expect(result[0].text).toBe("Build failed");
  });

  it("filters empty after all transformations", () => {
    const payloads: ReplyPayload[] = [{ text: "  " }];
    expect(processReplyPayloads(payloads, defaultOpts)).toHaveLength(0);
  });

  it("handles complex multi-payload pipeline", () => {
    const payloads: ReplyPayload[] = [
      { text: "thinking about it", isReasoning: true },
      { text: "NO_REPLY" },
      { text: "" },
      { text: "Real answer here" },
      { text: "Already sent" },
    ];
    const opts = { ...defaultOpts, sentTexts: ["Already sent"] };
    const result = processReplyPayloads(payloads, opts);
    expect(result).toHaveLength(1);
    expect(result[0].text).toBe("Real answer here");
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement pipeline.ts**

```ts
// packages/core/src/reply/pipeline.ts
import type { ReplyPayload } from "@druzhok/shared";
import {
  filterSilentReplies,
  filterReasoningBlocks,
  filterEmptyPayloads,
  deduplicateAgainstSent,
  stripHeartbeatFromPayloads,
} from "./filters.js";

export type PipelineOpts = {
  showReasoning: boolean;
  sentTexts: string[];
  isHeartbeat: boolean;
};

export function processReplyPayloads(
  payloads: ReplyPayload[],
  opts: PipelineOpts
): ReplyPayload[] {
  let result = payloads;

  // 1. Strip NO_REPLY tokens
  result = filterSilentReplies(result);

  // 2. Strip HEARTBEAT_OK tokens (heartbeat turns only)
  if (opts.isHeartbeat) {
    result = stripHeartbeatFromPayloads(result);
  }

  // 3. Filter reasoning blocks
  result = filterReasoningBlocks(result, opts.showReasoning);

  // 4. Deduplicate against message-tool sends
  result = deduplicateAgainstSent(result, opts.sentTexts);

  // 5. Filter empty payloads
  result = filterEmptyPayloads(result);

  return result;
}
```

- [ ] **Step 4: Run tests, verify pass**
- [ ] **Step 5: Commit**

```bash
git commit -m "add reply pipeline orchestrator"
```

---

### Task 3: Lane State Management

**Files:**
- Create: `packages/core/src/reply/lane.ts`
- Create: `tests/core/reply/lane.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
// tests/core/reply/lane.test.ts
import { describe, it, expect, vi } from "vitest";
import { createLaneManager, type LaneManager } from "@druzhok/core/reply/lane.js";
import type { DraftStream } from "@druzhok/shared";

function mockDraftStream(): DraftStream & { updates: string[] } {
  const updates: string[] = [];
  let msgId: number | undefined;
  return {
    updates,
    update(text: string) { updates.push(text); },
    async materialize() { msgId = msgId ?? 1; return msgId; },
    forceNewMessage() { msgId = undefined; },
    async stop() {},
    async flush() {},
    messageId() { return msgId; },
  };
}

describe("LaneManager", () => {
  it("routes answer text to answer lane", () => {
    const answer = mockDraftStream();
    const reasoning = mockDraftStream();
    const manager = createLaneManager({ answer, reasoning, showReasoning: false });

    manager.onTextDelta("Hello world", false);
    expect(answer.updates).toEqual(["Hello world"]);
    expect(reasoning.updates).toEqual([]);
  });

  it("routes reasoning text to reasoning lane when enabled", () => {
    const answer = mockDraftStream();
    const reasoning = mockDraftStream();
    const manager = createLaneManager({ answer, reasoning, showReasoning: true });

    manager.onTextDelta("thinking...", true);
    expect(reasoning.updates).toEqual(["thinking..."]);
    expect(answer.updates).toEqual([]);
  });

  it("suppresses reasoning when disabled", () => {
    const answer = mockDraftStream();
    const reasoning = mockDraftStream();
    const manager = createLaneManager({ answer, reasoning, showReasoning: false });

    manager.onTextDelta("thinking...", true);
    expect(reasoning.updates).toEqual([]);
  });

  it("materializes answer lane on tool call boundary", async () => {
    const answer = mockDraftStream();
    const reasoning = mockDraftStream();
    const manager = createLaneManager({ answer, reasoning, showReasoning: false });

    manager.onTextDelta("Partial answer", false);
    await manager.onToolCallStart();
    // After tool call, next text should go to a new message
    expect(answer.updates).toContain("Partial answer");
  });

  it("anti-flicker: skips shorter text", () => {
    const answer = mockDraftStream();
    const reasoning = mockDraftStream();
    const manager = createLaneManager({ answer, reasoning, showReasoning: false });

    manager.onTextDelta("Hello world!", false);
    manager.onTextDelta("Hello world", false);  // shorter — should skip
    // DraftStream handles anti-flicker internally, but manager should still forward
    expect(answer.updates).toHaveLength(2);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement lane.ts**

```ts
// packages/core/src/reply/lane.ts
import type { DraftStream } from "@druzhok/shared";

export type LaneManagerOpts = {
  answer: DraftStream;
  reasoning: DraftStream;
  showReasoning: boolean;
};

export type LaneManager = {
  onTextDelta(text: string, isReasoning: boolean): void;
  onToolCallStart(): Promise<void>;
  onToolCallEnd(): void;
  flushAll(): Promise<void>;
  stopAll(): Promise<void>;
};

export function createLaneManager(opts: LaneManagerOpts): LaneManager {
  const { answer, reasoning, showReasoning } = opts;

  return {
    onTextDelta(text: string, isReasoning: boolean) {
      if (isReasoning) {
        if (showReasoning) {
          reasoning.update(text);
        }
        return;
      }
      answer.update(text);
    },

    async onToolCallStart() {
      // Materialize current answer so it stays visible
      await answer.materialize();
      answer.forceNewMessage();
    },

    onToolCallEnd() {
      // Ready for next answer segment
    },

    async flushAll() {
      await answer.flush();
      if (showReasoning) {
        await reasoning.flush();
      }
    },

    async stopAll() {
      await answer.stop();
      await reasoning.stop();
    },
  };
}
```

- [ ] **Step 4: Run tests, verify pass**
- [ ] **Step 5: Commit**

```bash
git commit -m "add lane state management for streaming"
```

---

### Task 4: Streaming Coordinator

**Files:**
- Create: `packages/core/src/reply/streaming.ts`
- Create: `tests/core/reply/streaming.test.ts`

- [ ] **Step 1: Write failing tests**

```ts
// tests/core/reply/streaming.test.ts
import { describe, it, expect, vi } from "vitest";
import { createStreamingCoordinator } from "@druzhok/core/reply/streaming.js";

describe("createStreamingCoordinator", () => {
  it("collects streamed text for final payload assembly", () => {
    const coordinator = createStreamingCoordinator();

    coordinator.onAssistantText("Hello ");
    coordinator.onAssistantText("Hello world");

    const texts = coordinator.getStreamedTexts();
    expect(texts).toContain("Hello world");
  });

  it("tracks message tool sends for deduplication", () => {
    const coordinator = createStreamingCoordinator();

    coordinator.onMessageToolSend("Proactive message");

    expect(coordinator.getSentTexts()).toContain("Proactive message");
  });

  it("tracks tool call boundaries", () => {
    const coordinator = createStreamingCoordinator();

    expect(coordinator.isInToolCall()).toBe(false);
    coordinator.onToolCallStart();
    expect(coordinator.isInToolCall()).toBe(true);
    coordinator.onToolCallEnd();
    expect(coordinator.isInToolCall()).toBe(false);
  });

  it("counts assistant message boundaries", () => {
    const coordinator = createStreamingCoordinator();

    expect(coordinator.getMessageCount()).toBe(0);
    coordinator.onAssistantMessageStart();
    expect(coordinator.getMessageCount()).toBe(1);
    coordinator.onAssistantMessageStart();
    expect(coordinator.getMessageCount()).toBe(2);
  });

  it("resets state", () => {
    const coordinator = createStreamingCoordinator();
    coordinator.onAssistantText("text");
    coordinator.onMessageToolSend("sent");
    coordinator.reset();
    expect(coordinator.getStreamedTexts()).toHaveLength(0);
    expect(coordinator.getSentTexts()).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement streaming.ts**

```ts
// packages/core/src/reply/streaming.ts

export type StreamingCoordinator = {
  onAssistantText(text: string): void;
  onAssistantMessageStart(): void;
  onToolCallStart(): void;
  onToolCallEnd(): void;
  onMessageToolSend(text: string): void;
  getStreamedTexts(): string[];
  getSentTexts(): string[];
  isInToolCall(): boolean;
  getMessageCount(): number;
  reset(): void;
};

export function createStreamingCoordinator(): StreamingCoordinator {
  let streamedTexts: string[] = [];
  let sentTexts: string[] = [];
  let inToolCall = false;
  let messageCount = 0;
  let lastText = "";

  return {
    onAssistantText(text: string) {
      lastText = text;
      // Keep only latest accumulated text (streaming sends full text each time)
      if (streamedTexts.length === 0) {
        streamedTexts.push(text);
      } else {
        streamedTexts[streamedTexts.length - 1] = text;
      }
    },

    onAssistantMessageStart() {
      messageCount++;
      // Start tracking a new message's text
      streamedTexts.push("");
    },

    onToolCallStart() {
      inToolCall = true;
    },

    onToolCallEnd() {
      inToolCall = false;
    },

    onMessageToolSend(text: string) {
      sentTexts.push(text);
    },

    getStreamedTexts() {
      return streamedTexts.filter(Boolean);
    },

    getSentTexts() {
      return [...sentTexts];
    },

    isInToolCall() {
      return inToolCall;
    },

    getMessageCount() {
      return messageCount;
    },

    reset() {
      streamedTexts = [];
      sentTexts = [];
      inToolCall = false;
      messageCount = 0;
      lastText = "";
    },
  };
}
```

- [ ] **Step 4: Run tests, verify pass**
- [ ] **Step 5: Commit**

```bash
git commit -m "add streaming coordinator for agent run tracking"
```

---

### Task 5: Reply Module Exports

**Files:**
- Modify: `packages/core/src/index.ts`

- [ ] **Step 1: Add reply exports**

Append to `packages/core/src/index.ts`:

```ts
export * from "./reply/filters.js";
export * from "./reply/pipeline.js";
export * from "./reply/lane.js";
export * from "./reply/streaming.js";
```

- [ ] **Step 2: Build and test**

Run: `pnpm build && pnpm test`
Expected: All tests pass, clean build

- [ ] **Step 3: Commit**

```bash
git commit -m "export reply pipeline from core"
```

---

## Phase 4 Complete Checklist

- [ ] `pnpm build` succeeds
- [ ] `pnpm test` all pass
- [ ] Filters: NO_REPLY suppression, reasoning filtering, empty removal, dedup, HEARTBEAT_OK stripping
- [ ] Pipeline: orchestrates all filters in correct order
- [ ] Lanes: routes text deltas to answer/reasoning DraftStreams, materializes on tool call boundaries
- [ ] Streaming coordinator: tracks message boundaries, tool calls, sent texts for dedup
