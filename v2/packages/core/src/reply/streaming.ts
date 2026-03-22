export type StreamingCoordinator = {
  onAssistantText(text: string): void;
  onAssistantMessageStart(): void;
  onToolCallStart(): void;
  onToolCallEnd(): void;
  onMessageToolSend(text: string): void;
  getStreamedTexts(): string[];
  getSentTexts(): string[];
  isInToolCall(): boolean;
  getMessageCount(): number;
  reset(): void;
};

export function createStreamingCoordinator(): StreamingCoordinator {
  let streamedTexts: string[] = [];
  let sentTexts: string[] = [];
  let inToolCall = false;
  let messageCount = 0;

  return {
    onAssistantText(text: string) {
      if (streamedTexts.length === 0) streamedTexts.push(text);
      else streamedTexts[streamedTexts.length - 1] = text;
    },
    onAssistantMessageStart() { messageCount++; streamedTexts.push(""); },
    onToolCallStart() { inToolCall = true; },
    onToolCallEnd() { inToolCall = false; },
    onMessageToolSend(text: string) { sentTexts.push(text); },
    getStreamedTexts() { return streamedTexts.filter(Boolean); },
    getSentTexts() { return [...sentTexts]; },
    isInToolCall() { return inToolCall; },
    getMessageCount() { return messageCount; },
    reset() { streamedTexts = []; sentTexts = []; inToolCall = false; messageCount = 0; },
  };
}
