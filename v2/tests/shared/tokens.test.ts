import { describe, it, expect } from "vitest";
import {
  SILENT_REPLY_TOKEN,
  HEARTBEAT_TOKEN,
  isSilentReplyText,
  stripSilentToken,
  isHeartbeatOnly,
  stripHeartbeatToken,
} from "@druzhok/shared";

describe("isSilentReplyText", () => {
  it("matches exact NO_REPLY", () => {
    expect(isSilentReplyText("NO_REPLY")).toBe(true);
  });
  it("matches with surrounding whitespace", () => {
    expect(isSilentReplyText("  NO_REPLY  ")).toBe(true);
  });
  it("does not match NO_REPLY embedded in text", () => {
    expect(isSilentReplyText("Sure thing! NO_REPLY")).toBe(false);
  });
  it("returns false for undefined", () => {
    expect(isSilentReplyText(undefined)).toBe(false);
  });
  it("returns false for empty string", () => {
    expect(isSilentReplyText("")).toBe(false);
  });
});

describe("stripSilentToken", () => {
  it("strips trailing NO_REPLY", () => {
    expect(stripSilentToken("Some text NO_REPLY")).toBe("Some text");
  });
  it("strips trailing NO_REPLY with punctuation", () => {
    expect(stripSilentToken("Done. NO_REPLY")).toBe("Done.");
  });
  it("returns empty for NO_REPLY only", () => {
    expect(stripSilentToken("NO_REPLY")).toBe("");
  });
  it("returns text unchanged if no token", () => {
    expect(stripSilentToken("Hello world")).toBe("Hello world");
  });
});

describe("isHeartbeatOnly", () => {
  it("matches exact HEARTBEAT_OK", () => {
    expect(isHeartbeatOnly("HEARTBEAT_OK")).toBe(true);
  });
  it("matches with whitespace", () => {
    expect(isHeartbeatOnly("  HEARTBEAT_OK\n")).toBe(true);
  });
  it("does not match mixed content", () => {
    expect(isHeartbeatOnly("All good HEARTBEAT_OK")).toBe(false);
  });
});

describe("stripHeartbeatToken", () => {
  it("strips HEARTBEAT_OK from start", () => {
    expect(stripHeartbeatToken("HEARTBEAT_OK and more")).toBe("and more");
  });
  it("strips HEARTBEAT_OK from end", () => {
    expect(stripHeartbeatToken("Status fine HEARTBEAT_OK")).toBe("Status fine");
  });
  it("returns empty for HEARTBEAT_OK only", () => {
    expect(stripHeartbeatToken("HEARTBEAT_OK")).toBe("");
  });
});
