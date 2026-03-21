import { describe, it, expect, vi } from "vitest";
import { createDelivery, type TelegramApi } from "@druzhok/telegram/delivery.js";

describe("createDelivery", () => {
  const createMockApi = (): TelegramApi => ({
    sendMessage: vi.fn().mockResolvedValue({ message_id: 1 }),
    editMessageText: vi.fn().mockResolvedValue(undefined),
    deleteMessage: vi.fn().mockResolvedValue(true),
  });

  it("sends text message and returns delivery result", async () => {
    const api = createMockApi();
    const delivery = createDelivery(api);
    const result = await delivery.sendMessage("123", { text: "Hello" });
    expect(result.delivered).toBe(true);
    expect(result.messageId).toBe(1);
    expect(api.sendMessage).toHaveBeenCalledTimes(1);
  });

  it("chunks long messages", async () => {
    const api = createMockApi();
    const delivery = createDelivery(api);
    const longText = "x".repeat(5000);
    await delivery.sendMessage("123", { text: longText });
    expect(api.sendMessage).toHaveBeenCalledTimes(2);
  });

  it("skips empty payload", async () => {
    const api = createMockApi();
    const delivery = createDelivery(api);
    const result = await delivery.sendMessage("123", {});
    expect(result.delivered).toBe(false);
    expect(api.sendMessage).not.toHaveBeenCalled();
  });

  it("edits existing message", async () => {
    const api = createMockApi();
    const delivery = createDelivery(api);
    await delivery.editMessage("123", 42, { text: "Updated" });
    expect(api.editMessageText).toHaveBeenCalledWith("123", 42, expect.any(String), expect.any(Object));
  });

  it("deletes message", async () => {
    const api = createMockApi();
    const delivery = createDelivery(api);
    await delivery.deleteMessage("123", 42);
    expect(api.deleteMessage).toHaveBeenCalledWith("123", 42);
  });
});
