import type { DraftStream } from "@druzhok/shared";

export type LaneManagerOpts = { answer: DraftStream; reasoning: DraftStream; showReasoning: boolean };
export type LaneManager = {
  onTextDelta(text: string, isReasoning: boolean): void;
  onToolCallStart(): Promise<void>;
  onToolCallEnd(): void;
  flushAll(): Promise<void>;
  stopAll(): Promise<void>;
};

export function createLaneManager(opts: LaneManagerOpts): LaneManager {
  const { answer, reasoning, showReasoning } = opts;
  return {
    onTextDelta(text: string, isReasoning: boolean) {
      if (isReasoning) { if (showReasoning) reasoning.update(text); return; }
      answer.update(text);
    },
    async onToolCallStart() { await answer.materialize(); answer.forceNewMessage(); },
    onToolCallEnd() {},
    async flushAll() { await answer.flush(); if (showReasoning) await reasoning.flush(); },
    async stopAll() { await answer.stop(); await reasoning.stop(); },
  };
}
