import { describe, it, expect } from "vitest";
import {
  buildSessionKey,
  parseSessionKey,
  isHeartbeatSession,
} from "@druzhok/core/session/session-key.js";

describe("buildSessionKey", () => {
  it("builds DM session key", () => {
    expect(buildSessionKey({ channel: "telegram", chatType: "direct", chatId: "123" }))
      .toBe("telegram:dm:123");
  });
  it("builds group session key", () => {
    expect(buildSessionKey({ channel: "telegram", chatType: "group", chatId: "456" }))
      .toBe("telegram:group:456");
  });
  it("builds topic session key", () => {
    expect(buildSessionKey({ channel: "telegram", chatType: "group", chatId: "456", topicId: "7" }))
      .toBe("telegram:group:456:topic:7");
  });
});

describe("parseSessionKey", () => {
  it("parses DM key", () => {
    expect(parseSessionKey("telegram:dm:123")).toEqual({
      channel: "telegram", chatType: "direct", chatId: "123",
    });
  });
  it("parses group key", () => {
    expect(parseSessionKey("telegram:group:456")).toEqual({
      channel: "telegram", chatType: "group", chatId: "456",
    });
  });
  it("parses topic key", () => {
    expect(parseSessionKey("telegram:group:456:topic:7")).toEqual({
      channel: "telegram", chatType: "group", chatId: "456", topicId: "7",
    });
  });
  it("returns null for invalid key", () => {
    expect(parseSessionKey("garbage")).toBeNull();
  });
});

describe("isHeartbeatSession", () => {
  it("identifies heartbeat session", () => {
    expect(isHeartbeatSession("system:heartbeat")).toBe(true);
  });
  it("rejects normal session", () => {
    expect(isHeartbeatSession("telegram:dm:123")).toBe(false);
  });
});
