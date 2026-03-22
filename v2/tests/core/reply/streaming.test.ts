import { describe, it, expect } from "vitest";
import { createStreamingCoordinator } from "@druzhok/core/reply/streaming.js";

describe("createStreamingCoordinator", () => {
  it("collects streamed text", () => {
    const c = createStreamingCoordinator();
    c.onAssistantText("Hello ");
    c.onAssistantText("Hello world");
    expect(c.getStreamedTexts()).toContain("Hello world");
  });
  it("tracks message tool sends", () => {
    const c = createStreamingCoordinator();
    c.onMessageToolSend("Proactive message");
    expect(c.getSentTexts()).toContain("Proactive message");
  });
  it("tracks tool call boundaries", () => {
    const c = createStreamingCoordinator();
    expect(c.isInToolCall()).toBe(false);
    c.onToolCallStart();
    expect(c.isInToolCall()).toBe(true);
    c.onToolCallEnd();
    expect(c.isInToolCall()).toBe(false);
  });
  it("counts assistant message boundaries", () => {
    const c = createStreamingCoordinator();
    expect(c.getMessageCount()).toBe(0);
    c.onAssistantMessageStart();
    expect(c.getMessageCount()).toBe(1);
    c.onAssistantMessageStart();
    expect(c.getMessageCount()).toBe(2);
  });
  it("resets state", () => {
    const c = createStreamingCoordinator();
    c.onAssistantText("text");
    c.onMessageToolSend("sent");
    c.reset();
    expect(c.getStreamedTexts()).toHaveLength(0);
    expect(c.getSentTexts()).toHaveLength(0);
  });
});
