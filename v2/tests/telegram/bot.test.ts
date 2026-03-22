import { describe, it, expect } from "vitest";
import { classifyUpdate } from "@druzhok/telegram/bot.js";

describe("classifyUpdate", () => {
  it("classifies text message", () => {
    expect(classifyUpdate({ message: { message_id: 1, date: Date.now()/1000, chat: { id: 123, type: "private" }, from: { id: 456, first_name: "Igor", is_bot: false }, text: "Hello" } })).toBe("message");
  });
  it("classifies command", () => {
    expect(classifyUpdate({ message: { message_id: 1, date: Date.now()/1000, chat: { id: 123, type: "private" }, from: { id: 456, first_name: "Igor", is_bot: false }, text: "/start" } })).toBe("command");
  });
  it("classifies photo message", () => {
    expect(classifyUpdate({ message: { message_id: 1, date: Date.now()/1000, chat: { id: 123, type: "private" }, from: { id: 456, first_name: "Igor", is_bot: false }, photo: [{ file_id: "abc", file_unique_id: "def", width: 100, height: 100 }], caption: "Look" } })).toBe("message");
  });
  it("ignores bot messages", () => {
    expect(classifyUpdate({ message: { message_id: 1, date: Date.now()/1000, chat: { id: 123, type: "private" }, from: { id: 456, first_name: "Bot", is_bot: true }, text: "I am a bot" } })).toBe("ignore");
  });
  it("ignores updates without message", () => { expect(classifyUpdate({})).toBe("ignore"); });
  it("classifies unknown commands as message", () => {
    expect(classifyUpdate({ message: { message_id: 1, date: Date.now()/1000, chat: { id: 123, type: "private" }, from: { id: 456, first_name: "Igor", is_bot: false }, text: "/unknown_command" } })).toBe("message");
  });
});
