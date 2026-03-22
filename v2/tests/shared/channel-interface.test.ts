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
