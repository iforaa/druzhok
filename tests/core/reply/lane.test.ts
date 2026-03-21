import { describe, it, expect, vi } from "vitest";
import { createLaneManager } from "@druzhok/core/reply/lane.js";
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
    expect(answer.updates).toContain("Partial answer");
  });
  it("anti-flicker: forwards all text (DraftStream handles filtering)", () => {
    const answer = mockDraftStream();
    const reasoning = mockDraftStream();
    const manager = createLaneManager({ answer, reasoning, showReasoning: false });
    manager.onTextDelta("Hello world!", false);
    manager.onTextDelta("Hello world", false);
    expect(answer.updates).toHaveLength(2);
  });
});
