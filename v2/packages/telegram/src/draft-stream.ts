import type { DraftStream } from "@druzhok/shared";

export type DraftStreamDeps = {
  send: (text: string) => Promise<number>;
  edit: (messageId: number, text: string) => Promise<void>;
  minInitialChars?: number;
};

export function createDraftStream(deps: DraftStreamDeps): DraftStream {
  const minChars = deps.minInitialChars ?? 30;
  let currentMessageId: number | undefined;
  let lastText = "";
  let pendingText: string | null = null;
  let isStopped = false;

  return {
    update(text: string) {
      if (isStopped) return;
      if (lastText && text.length < lastText.length && lastText.startsWith(text)) return;
      pendingText = text;
    },
    async flush() {
      if (pendingText === null || isStopped) return;
      const text = pendingText;
      pendingText = null;
      if (currentMessageId === undefined) {
        if (text.length < minChars) return;
        currentMessageId = await deps.send(text);
        lastText = text;
      } else {
        if (text === lastText) return;
        await deps.edit(currentMessageId, text);
        lastText = text;
      }
    },
    async materialize() { await this.flush(); return currentMessageId ?? 0; },
    forceNewMessage() { currentMessageId = undefined; lastText = ""; pendingText = null; },
    async stop() { isStopped = true; await this.flush(); },
    messageId() { return currentMessageId; },
  };
}
