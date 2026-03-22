import { describe, it, expect } from "vitest";
import { processReplyPayloads, type PipelineOpts } from "@druzhok/core/reply/pipeline.js";
import type { ReplyPayload } from "@druzhok/shared";

const defaultOpts: PipelineOpts = { showReasoning: false, sentTexts: [], isHeartbeat: false };

describe("processReplyPayloads", () => {
  it("passes through normal payloads", () => { expect(processReplyPayloads([{ text: "Hello" }], defaultOpts)).toHaveLength(1); });
  it("filters NO_REPLY", () => { expect(processReplyPayloads([{ text: "NO_REPLY" }], defaultOpts)).toHaveLength(0); });
  it("filters reasoning blocks", () => {
    expect(processReplyPayloads([{ text: "thinking", isReasoning: true }, { text: "answer" }], defaultOpts)).toHaveLength(1);
  });
  it("deduplicates against sent texts", () => {
    expect(processReplyPayloads([{ text: "Already sent" }], { ...defaultOpts, sentTexts: ["Already sent"] })).toHaveLength(0);
  });
  it("strips HEARTBEAT_OK in heartbeat mode", () => {
    expect(processReplyPayloads([{ text: "HEARTBEAT_OK" }], { ...defaultOpts, isHeartbeat: true })).toHaveLength(0);
  });
  it("strips HEARTBEAT_OK from mixed heartbeat text", () => {
    const result = processReplyPayloads([{ text: "Build failed HEARTBEAT_OK" }], { ...defaultOpts, isHeartbeat: true });
    expect(result).toHaveLength(1);
    expect(result[0].text).toBe("Build failed");
  });
  it("filters empty after all transformations", () => { expect(processReplyPayloads([{ text: "  " }], defaultOpts)).toHaveLength(0); });
  it("handles complex multi-payload pipeline", () => {
    const payloads: ReplyPayload[] = [
      { text: "thinking about it", isReasoning: true }, { text: "NO_REPLY" }, { text: "" },
      { text: "Real answer here" }, { text: "Already sent" },
    ];
    const result = processReplyPayloads(payloads, { ...defaultOpts, sentTexts: ["Already sent"] });
    expect(result).toHaveLength(1);
    expect(result[0].text).toBe("Real answer here");
  });
});
