import { describe, it, expect } from "vitest";
import {
  translateOpenAIToAnthropic,
  translateAnthropicStreamEvent,
  translateAnthropicResponse,
  createStreamState,
} from "@druzhok/proxy/providers/anthropic.js";

describe("translateOpenAIToAnthropic", () => {
  it("extracts system message", () => {
    const openaiBody = {
      model: "claude-sonnet-4-20250514",
      messages: [
        { role: "system", content: "You are helpful" },
        { role: "user", content: "Hello" },
      ],
      stream: true,
    };
    const result = translateOpenAIToAnthropic(openaiBody);
    expect(result.system).toBe("You are helpful");
    expect(result.messages).toEqual([{ role: "user", content: "Hello" }]);
    expect(result.model).toBe("claude-sonnet-4-20250514");
    expect(result.max_tokens).toBeGreaterThan(0);
    expect(result.stream).toBe(true);
  });
  it("handles no system message", () => {
    const openaiBody = {
      model: "claude-sonnet-4-20250514",
      messages: [{ role: "user", content: "Hello" }],
    };
    const result = translateOpenAIToAnthropic(openaiBody);
    expect(result.system).toBeUndefined();
    expect(result.messages).toEqual([{ role: "user", content: "Hello" }]);
  });
  it("passes through tools", () => {
    const openaiBody = {
      model: "claude-sonnet-4-20250514",
      messages: [{ role: "user", content: "Hello" }],
      tools: [{ type: "function", function: { name: "test" } }],
    };
    const result = translateOpenAIToAnthropic(openaiBody);
    expect(result.tools).toBeDefined();
  });
});

describe("translateAnthropicStreamEvent", () => {
  it("translates content_block_delta to OpenAI format", () => {
    const event = { type: "content_block_delta", delta: { type: "text_delta", text: "Hello" } };
    const result = translateAnthropicStreamEvent(event);
    expect(result).toEqual({ choices: [{ index: 0, delta: { content: "Hello" } }] });
  });
  it("translates message_stop to done", () => {
    const event = { type: "message_stop" };
    const result = translateAnthropicStreamEvent(event);
    expect(result).toBe("[DONE]");
  });
  it("returns null for non-content events", () => {
    const event = { type: "ping" };
    const result = translateAnthropicStreamEvent(event);
    expect(result).toBeNull();
  });
  it("translates tool_use content_block_start", () => {
    const state = createStreamState();
    const event = { type: "content_block_start", content_block: { type: "tool_use", id: "call_1", name: "read" } };
    const result = translateAnthropicStreamEvent(event as any, state);
    expect(result).toEqual({
      choices: [{ index: 0, delta: { tool_calls: [{ index: 0, id: "call_1", type: "function", function: { name: "read", arguments: "" } }] } }],
    });
  });
  it("translates input_json_delta", () => {
    const state = createStreamState();
    state.currentToolIndex = 0;
    const event = { type: "content_block_delta", delta: { type: "input_json_delta", partial_json: '{"path":' } };
    const result = translateAnthropicStreamEvent(event as any, state);
    expect(result).toEqual({
      choices: [{ index: 0, delta: { tool_calls: [{ index: 0, function: { arguments: '{"path":' } }] } }],
    });
  });
});

describe("translateAnthropicResponse", () => {
  it("translates text response", () => {
    const response = {
      id: "msg_1", model: "claude-sonnet-4-20250514",
      content: [{ type: "text", text: "Hello" }],
      stop_reason: "end_turn", usage: { input_tokens: 10, output_tokens: 5 },
    };
    const result = translateAnthropicResponse(response);
    expect(result.id).toBe("msg_1");
    expect(result.model).toBe("claude-sonnet-4-20250514");
    expect((result.choices as any)[0].message.content).toBe("Hello");
    expect((result.choices as any)[0].finish_reason).toBe("stop");
  });
  it("translates tool_use response", () => {
    const response = {
      id: "msg_2", model: "claude-sonnet-4-20250514",
      content: [
        { type: "text", text: "Let me read that." },
        { type: "tool_use", id: "call_1", name: "read", input: { path: "/tmp" } },
      ],
      stop_reason: "tool_use", usage: { input_tokens: 10, output_tokens: 20 },
    };
    const result = translateAnthropicResponse(response);
    const choice = (result.choices as any)[0];
    expect(choice.finish_reason).toBe("tool_calls");
    expect(choice.message.tool_calls).toHaveLength(1);
    expect(choice.message.tool_calls[0].function.name).toBe("read");
    expect(choice.message.tool_calls[0].function.arguments).toBe('{"path":"/tmp"}');
  });
});
