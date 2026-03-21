const DEFAULT_MAX_TOKENS = 8192;

type OpenAIMessage = { role: string; content: string | unknown[] };
type AnthropicRequest = { model: string; messages: OpenAIMessage[]; system?: string; max_tokens: number; stream?: boolean; tools?: unknown[]; temperature?: number; top_p?: number };

export function translateOpenAIToAnthropic(body: Record<string, unknown>): AnthropicRequest {
  const messages = (body.messages as OpenAIMessage[]) ?? [];
  const systemMessages = messages.filter((m) => m.role === "system");
  const nonSystemMessages = messages.filter((m) => m.role !== "system");
  const systemText = systemMessages.map((m) => (typeof m.content === "string" ? m.content : JSON.stringify(m.content))).join("\n\n");
  const result: AnthropicRequest = { model: body.model as string, messages: nonSystemMessages, max_tokens: (body.max_tokens as number) ?? DEFAULT_MAX_TOKENS, stream: body.stream as boolean | undefined };
  if (systemText) result.system = systemText;
  if (body.tools) result.tools = body.tools as unknown[];
  if (body.temperature !== undefined) result.temperature = body.temperature as number;
  if (body.top_p !== undefined) result.top_p = body.top_p as number;
  return result;
}

export type AnthropicStreamEvent = { type: string; delta?: { type?: string; text?: string }; [key: string]: unknown };
type OpenAIStreamChunk = { choices: Array<{ index: number; delta: Record<string, unknown> }> };

export type StreamTranslationState = { currentToolIndex: number; toolCallId: string | null };
export function createStreamState(): StreamTranslationState { return { currentToolIndex: -1, toolCallId: null }; }

export function translateAnthropicStreamEvent(event: AnthropicStreamEvent, state?: StreamTranslationState): OpenAIStreamChunk | "[DONE]" | null {
  switch (event.type) {
    case "content_block_delta":
      if (event.delta?.type === "text_delta" && event.delta.text) {
        return { choices: [{ index: 0, delta: { content: event.delta.text } }] };
      }
      if (event.delta?.type === "input_json_delta" && state) {
        return { choices: [{ index: 0, delta: { tool_calls: [{ index: state.currentToolIndex, function: { arguments: (event.delta as Record<string, string>).partial_json ?? "" } }] } }] };
      }
      return null;
    case "content_block_start": {
      const block = (event as Record<string, unknown>).content_block as Record<string, unknown> | undefined;
      if (block?.type === "tool_use" && state) {
        state.currentToolIndex++;
        state.toolCallId = (block.id as string) ?? null;
        return { choices: [{ index: 0, delta: { tool_calls: [{ index: state.currentToolIndex, id: block.id as string, type: "function", function: { name: block.name as string, arguments: "" } }] } }] };
      }
      return null;
    }
    case "message_start":
      return { choices: [{ index: 0, delta: { role: "assistant" } }] };
    case "message_stop":
      return "[DONE]";
    default:
      return null;
  }
}

export function translateAnthropicResponse(response: Record<string, unknown>): Record<string, unknown> {
  const content = (response.content as Array<Record<string, unknown>>) ?? [];
  const textParts = content.filter((b) => b.type === "text").map((b) => b.text as string);
  const toolCalls = content.filter((b) => b.type === "tool_use").map((b, i) => ({ index: i, id: b.id as string, type: "function", function: { name: b.name as string, arguments: JSON.stringify(b.input) } }));
  const message: Record<string, unknown> = { role: "assistant", content: textParts.join("") || null };
  if (toolCalls.length > 0) message.tool_calls = toolCalls;
  return {
    id: response.id ?? `chatcmpl-${Date.now()}`,
    object: "chat.completion",
    model: response.model,
    choices: [{ index: 0, message, finish_reason: response.stop_reason === "end_turn" ? "stop" : response.stop_reason === "tool_use" ? "tool_calls" : (response.stop_reason as string) ?? "stop" }],
    usage: response.usage,
  };
}

export async function forwardToAnthropic(opts: { apiKey: string; baseUrl: string; model: string; body: unknown; stream: boolean }): Promise<Response> {
  const anthropicBody = translateOpenAIToAnthropic({ ...(opts.body as Record<string, unknown>), model: opts.model, stream: opts.stream });
  return fetch(`${opts.baseUrl}/v1/messages`, { method: "POST", headers: { "Content-Type": "application/json", "x-api-key": opts.apiKey, "anthropic-version": "2023-06-01" }, body: JSON.stringify(anthropicBody) });
}
