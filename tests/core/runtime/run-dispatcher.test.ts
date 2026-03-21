import { describe, it, expect, vi } from "vitest";
import { createRunDispatcher } from "@druzhok/core/runtime/run-dispatcher.js";
import type { InboundContext, Channel } from "@druzhok/shared";

function mockChannel(): Channel {
  return {
    start: vi.fn().mockResolvedValue(undefined),
    stop: vi.fn().mockResolvedValue(undefined),
    onMessage: vi.fn().mockResolvedValue(undefined),
    sendMessage: vi.fn().mockResolvedValue({ delivered: true, messageId: 1 }),
    editMessage: vi.fn().mockResolvedValue(undefined),
    deleteMessage: vi.fn().mockResolvedValue(undefined),
    createDraftStream: vi.fn().mockReturnValue({
      update: vi.fn(), materialize: vi.fn().mockResolvedValue(1), forceNewMessage: vi.fn(),
      stop: vi.fn().mockResolvedValue(undefined), flush: vi.fn().mockResolvedValue(undefined), messageId: vi.fn().mockReturnValue(undefined),
    }),
    sendTyping: vi.fn().mockResolvedValue(undefined),
    setReaction: vi.fn().mockResolvedValue(undefined),
  };
}

function baseContext(): InboundContext {
  return { body: "Hello bot", from: "telegram:dm:123", chatId: "123", chatType: "direct", senderId: "456", senderName: "Igor", messageId: 42, sessionKey: "telegram:dm:456", timestamp: Date.now() };
}

describe("createRunDispatcher", () => {
  it("dispatches message and delivers response", async () => {
    const channel = mockChannel();
    const dispatcher = createRunDispatcher({
      channel,
      runAgent: async () => ({ payloads: [{ text: "Hello!" }] }),
      config: { proxyUrl: "http://proxy:8080", proxyKey: "key", defaultModel: "openai/gpt-4o", workspaceDir: "/tmp/workspace", chats: {} },
      agentsMd: "You are helpful.", soulMd: null, identityMd: null, userMd: null, skillsList: [],
    });
    await dispatcher.dispatch(baseContext());
    expect(channel.sendMessage).toHaveBeenCalledWith("123", expect.objectContaining({ text: "Hello!" }));
  });

  it("sends typing indicator before run", async () => {
    const channel = mockChannel();
    const dispatcher = createRunDispatcher({
      channel, runAgent: async () => ({ payloads: [{ text: "response" }] }),
      config: { proxyUrl: "", proxyKey: "", defaultModel: "", workspaceDir: "/tmp", chats: {} },
      agentsMd: null, soulMd: null, identityMd: null, userMd: null, skillsList: [],
    });
    await dispatcher.dispatch(baseContext());
    expect(channel.sendTyping).toHaveBeenCalledWith("123");
  });

  it("filters NO_REPLY responses", async () => {
    const channel = mockChannel();
    const dispatcher = createRunDispatcher({
      channel, runAgent: async () => ({ payloads: [{ text: "NO_REPLY" }] }),
      config: { proxyUrl: "", proxyKey: "", defaultModel: "", workspaceDir: "/tmp", chats: {} },
      agentsMd: null, soulMd: null, identityMd: null, userMd: null, skillsList: [],
    });
    await dispatcher.dispatch(baseContext());
    expect(channel.sendMessage).not.toHaveBeenCalled();
  });

  it("delivers error payload on agent failure", async () => {
    const channel = mockChannel();
    const dispatcher = createRunDispatcher({
      channel, runAgent: async () => { throw new Error("Provider down"); },
      config: { proxyUrl: "", proxyKey: "", defaultModel: "", workspaceDir: "/tmp", chats: {} },
      agentsMd: null, soulMd: null, identityMd: null, userMd: null, skillsList: [],
    });
    await dispatcher.dispatch(baseContext());
    expect(channel.sendMessage).toHaveBeenCalledWith("123", expect.objectContaining({ isError: true }));
  });

  it("applies per-chat model override", async () => {
    const channel = mockChannel();
    let capturedModel = "";
    const dispatcher = createRunDispatcher({
      channel,
      runAgent: async (opts) => { capturedModel = opts.model; return { payloads: [{ text: "ok" }] }; },
      config: { proxyUrl: "", proxyKey: "", defaultModel: "openai/gpt-4o", workspaceDir: "/tmp",
        chats: { "telegram:dm:456": { model: "anthropic/claude-sonnet-4-20250514" } } },
      agentsMd: null, soulMd: null, identityMd: null, userMd: null, skillsList: [],
    });
    await dispatcher.dispatch(baseContext());
    expect(capturedModel).toBe("anthropic/claude-sonnet-4-20250514");
  });
});
