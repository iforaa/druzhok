import { describe, it, expect } from "vitest";
import { parseCommand } from "@druzhok/telegram/commands.js";

describe("parseCommand", () => {
  it("parses /start", () => { expect(parseCommand("/start")).toEqual({ command: "start", args: "" }); });
  it("parses /model with args", () => { expect(parseCommand("/model anthropic/claude-sonnet-4-20250514")).toEqual({ command: "model", args: "anthropic/claude-sonnet-4-20250514" }); });
  it("parses /prompt with multi-word args", () => { expect(parseCommand("/prompt You are a helpful assistant")).toEqual({ command: "prompt", args: "You are a helpful assistant" }); });
  it("parses /reset", () => { expect(parseCommand("/reset")).toEqual({ command: "reset", args: "" }); });
  it("parses /stop", () => { expect(parseCommand("/stop")).toEqual({ command: "stop", args: "" }); });
  it("returns null for non-command text", () => { expect(parseCommand("hello world")).toBeNull(); });
  it("returns null for empty string", () => { expect(parseCommand("")).toBeNull(); });
  it("strips bot username from command", () => { expect(parseCommand("/start@mybot")).toEqual({ command: "start", args: "" }); });
  it("returns null for unknown commands", () => { expect(parseCommand("/unknown")).toBeNull(); });
});
