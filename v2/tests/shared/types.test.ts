import { describe, it, expect } from "vitest";
import type { ReplyPayload, InboundContext, DeliveryResult } from "@druzhok/shared";

describe("types", () => {
  it("ReplyPayload accepts minimal payload", () => {
    const payload: ReplyPayload = { text: "hello" };
    expect(payload.text).toBe("hello");
    expect(payload.isReasoning).toBeUndefined();
  });

  it("ReplyPayload accepts full payload", () => {
    const payload: ReplyPayload = {
      text: "response",
      mediaUrl: "file:///tmp/img.png",
      mediaUrls: ["file:///tmp/img.png"],
      isReasoning: false,
      isError: false,
      isSilent: false,
      replyToId: 42,
      audioAsVoice: true,
    };
    expect(payload.replyToId).toBe(42);
  });

  it("InboundContext has required fields", () => {
    const ctx: InboundContext = {
      body: "hello",
      from: "telegram:dm:123",
      chatId: "123",
      chatType: "direct",
      senderId: "456",
      senderName: "Igor",
      messageId: 1,
      sessionKey: "telegram:dm:123",
      timestamp: Date.now(),
    };
    expect(ctx.chatType).toBe("direct");
  });
});
