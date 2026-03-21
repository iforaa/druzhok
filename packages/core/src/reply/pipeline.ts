import type { ReplyPayload } from "@druzhok/shared";
import { filterSilentReplies, filterReasoningBlocks, filterEmptyPayloads, deduplicateAgainstSent, stripHeartbeatFromPayloads } from "./filters.js";

export type PipelineOpts = { showReasoning: boolean; sentTexts: string[]; isHeartbeat: boolean };

export function processReplyPayloads(payloads: ReplyPayload[], opts: PipelineOpts): ReplyPayload[] {
  let result = payloads;
  result = filterSilentReplies(result);
  if (opts.isHeartbeat) result = stripHeartbeatFromPayloads(result);
  result = filterReasoningBlocks(result, opts.showReasoning);
  result = deduplicateAgainstSent(result, opts.sentTexts);
  result = filterEmptyPayloads(result);
  return result;
}
