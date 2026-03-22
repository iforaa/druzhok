import { describe, it, expect } from "vitest";
import { buildInboundContext } from "@druzhok/telegram/context.js";

describe("buildInboundContext", () => {
  const baseUpdate = {
    message: {
      message_id: 42, date: 1711036800,
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
    const update = { message: { ...baseUpdate.message, chat: { id: -789, type: "group" as const, title: "My Group" } } };
    const ctx = buildInboundContext(update);
    expect(ctx.chatType).toBe("group");
    expect(ctx.chatId).toBe("-789");
    expect(ctx.sessionKey).toBe("telegram:group:-789");
  });

  it("builds supergroup context", () => {
    const update = { message: { ...baseUpdate.message, chat: { id: -100789, type: "supergroup" as const, title: "Super" } } };
    const ctx = buildInboundContext(update);
    expect(ctx.chatType).toBe("group");
    expect(ctx.sessionKey).toBe("telegram:group:-100789");
  });

  it("builds forum topic context", () => {
    const update = { message: { ...baseUpdate.message, chat: { id: -100789, type: "supergroup" as const, title: "Forum", is_forum: true }, message_thread_id: 7 } };
    const ctx = buildInboundContext(update);
    expect(ctx.sessionKey).toBe("telegram:group:-100789:topic:7");
  });

  it("builds reply context", () => {
    const update = { message: { ...baseUpdate.message, reply_to_message: { message_id: 40, date: 1711036700, chat: { id: 123, type: "private" as const }, from: { id: 789, first_name: "Bot", is_bot: true }, text: "Previous message" } } };
    const ctx = buildInboundContext(update);
    expect(ctx.replyTo).toBeDefined();
    expect(ctx.replyTo!.messageId).toBe(40);
    expect(ctx.replyTo!.body).toBe("Previous message");
    expect(ctx.replyTo!.senderName).toBe("Bot");
  });

  it("handles missing text (caption)", () => {
    const update = { message: { ...baseUpdate.message, text: undefined, caption: "Photo caption" } };
    const ctx = buildInboundContext(update);
    expect(ctx.body).toBe("Photo caption");
  });

  it("handles fully empty message", () => {
    const update = { message: { ...baseUpdate.message, text: undefined } };
    const ctx = buildInboundContext(update);
    expect(ctx.body).toBe("");
  });

  it("builds sender name from first + last name", () => {
    const update = { message: { ...baseUpdate.message, from: { id: 456, first_name: "Igor", last_name: "K", is_bot: false } } };
    const ctx = buildInboundContext(update);
    expect(ctx.senderName).toBe("Igor K");
  });
});
