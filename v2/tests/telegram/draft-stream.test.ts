import { describe, it, expect, vi, beforeEach } from "vitest";
import { createDraftStream } from "@druzhok/telegram/draft-stream.js";

describe("createDraftStream", () => {
  let mockSend: ReturnType<typeof vi.fn>;
  let mockEdit: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    vi.useFakeTimers();
    mockSend = vi.fn().mockResolvedValue(42);
    mockEdit = vi.fn().mockResolvedValue(undefined);
  });

  it("does not send until minInitialChars reached", () => {
    const stream = createDraftStream({ send: mockSend, edit: mockEdit, minInitialChars: 30 });
    stream.update("Hi");
    vi.advanceTimersByTime(2000);
    expect(mockSend).not.toHaveBeenCalled();
  });

  it("sends first message once minInitialChars reached", async () => {
    const stream = createDraftStream({ send: mockSend, edit: mockEdit, minInitialChars: 10 });
    stream.update("Hello, this is a long enough message");
    await stream.flush();
    expect(mockSend).toHaveBeenCalledWith("Hello, this is a long enough message");
  });

  it("edits subsequent updates", async () => {
    const stream = createDraftStream({ send: mockSend, edit: mockEdit, minInitialChars: 5 });
    stream.update("Hello world");
    await stream.flush();
    expect(mockSend).toHaveBeenCalledTimes(1);
    stream.update("Hello world, more text");
    await stream.flush();
    expect(mockEdit).toHaveBeenCalledWith(42, "Hello world, more text");
  });

  it("skips shorter text (anti-flicker)", async () => {
    const stream = createDraftStream({ send: mockSend, edit: mockEdit, minInitialChars: 5 });
    stream.update("Hello world!");
    await stream.flush();
    stream.update("Hello world");
    await stream.flush();
    expect(mockEdit).not.toHaveBeenCalled();
  });

  it("messageId returns undefined before first send", () => {
    const stream = createDraftStream({ send: mockSend, edit: mockEdit, minInitialChars: 30 });
    expect(stream.messageId()).toBeUndefined();
  });

  it("messageId returns id after first send", async () => {
    const stream = createDraftStream({ send: mockSend, edit: mockEdit, minInitialChars: 5 });
    stream.update("Hello world");
    await stream.flush();
    expect(stream.messageId()).toBe(42);
  });

  it("materialize returns message id", async () => {
    const stream = createDraftStream({ send: mockSend, edit: mockEdit, minInitialChars: 5 });
    stream.update("Hello world");
    await stream.flush();
    const id = await stream.materialize();
    expect(id).toBe(42);
  });

  it("forceNewMessage resets for next send", async () => {
    const stream = createDraftStream({ send: mockSend, edit: mockEdit, minInitialChars: 5 });
    stream.update("First message here");
    await stream.flush();
    expect(mockSend).toHaveBeenCalledTimes(1);
    stream.forceNewMessage();
    mockSend.mockResolvedValue(99);
    stream.update("Second message here");
    await stream.flush();
    expect(mockSend).toHaveBeenCalledTimes(2);
    expect(stream.messageId()).toBe(99);
  });
});
