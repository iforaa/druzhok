import { describe, it, expect } from "vitest";
import { filterSilentReplies, filterReasoningBlocks, filterEmptyPayloads, deduplicateAgainstSent, stripHeartbeatFromPayloads } from "@druzhok/core/reply/filters.js";
import type { ReplyPayload } from "@druzhok/shared";

describe("filterSilentReplies", () => {
  it("removes NO_REPLY-only payloads", () => { expect(filterSilentReplies([{ text: "NO_REPLY" }])).toHaveLength(0); });
  it("keeps payloads with real text", () => { expect(filterSilentReplies([{ text: "Hello world" }])).toHaveLength(1); });
  it("strips trailing NO_REPLY from mixed text", () => {
    const filtered = filterSilentReplies([{ text: "Done. NO_REPLY" }]);
    expect(filtered).toHaveLength(1);
    expect(filtered[0].text).toBe("Done.");
  });
  it("removes payloads with only whitespace + NO_REPLY", () => { expect(filterSilentReplies([{ text: "  NO_REPLY  " }])).toHaveLength(0); });
});

describe("filterReasoningBlocks", () => {
  it("removes reasoning payloads by default", () => {
    const result = filterReasoningBlocks([{ text: "thinking...", isReasoning: true }, { text: "Here is my answer" }], false);
    expect(result).toHaveLength(1);
    expect(result[0].text).toBe("Here is my answer");
  });
  it("keeps reasoning payloads when enabled", () => { expect(filterReasoningBlocks([{ text: "thinking...", isReasoning: true }, { text: "answer" }], true)).toHaveLength(2); });
});

describe("filterEmptyPayloads", () => {
  it("removes payloads with no text and no media", () => { expect(filterEmptyPayloads([{}])).toHaveLength(0); });
  it("keeps payloads with text", () => { expect(filterEmptyPayloads([{ text: "hello" }])).toHaveLength(1); });
  it("keeps payloads with media", () => { expect(filterEmptyPayloads([{ mediaUrl: "file:///tmp/img.png" }])).toHaveLength(1); });
  it("removes whitespace-only text payloads", () => { expect(filterEmptyPayloads([{ text: "   " }])).toHaveLength(0); });
});

describe("deduplicateAgainstSent", () => {
  it("removes payloads matching already-sent text", () => { expect(deduplicateAgainstSent([{ text: "Hello world" }], ["Hello world"])).toHaveLength(0); });
  it("keeps payloads that differ from sent", () => { expect(deduplicateAgainstSent([{ text: "New message" }], ["Old message"])).toHaveLength(1); });
  it("handles empty sent list", () => { expect(deduplicateAgainstSent([{ text: "Hello" }], [])).toHaveLength(1); });
});

describe("stripHeartbeatFromPayloads", () => {
  it("removes HEARTBEAT_OK-only payloads", () => { expect(stripHeartbeatFromPayloads([{ text: "HEARTBEAT_OK" }])).toHaveLength(0); });
  it("strips HEARTBEAT_OK from mixed text", () => {
    const filtered = stripHeartbeatFromPayloads([{ text: "Build failed! HEARTBEAT_OK" }]);
    expect(filtered).toHaveLength(1);
    expect(filtered[0].text).toBe("Build failed!");
  });
  it("keeps normal payloads unchanged", () => { expect(stripHeartbeatFromPayloads([{ text: "Normal response" }])).toHaveLength(1); });
});
