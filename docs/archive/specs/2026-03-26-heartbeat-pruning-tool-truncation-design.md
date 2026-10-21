# Heartbeat Pruning + Tool Result Truncation

**Date:** 2026-03-26
**Status:** Approved

## Problem

Two sources of token waste in conversation history:

1. **Heartbeat exchanges accumulate** — each heartbeat tick adds a user prompt + tool calls (memory_search, bash date) + tool results (~1-3K tokens each) + assistant "HEARTBEAT_OK" response. With 25+ ticks, that's ~20-30K tokens of waste. We suppress sending HEARTBEAT_OK to Telegram, but the full exchange is still stored in session history and sent as context to every subsequent LLM call.

2. **Old tool results sent in full** — a single `web_fetch` of an RSS feed can return 20K+ tokens of XML/HTML. A failed Google search returns 10K+ of obfuscated JavaScript. These are stored in full and sent to the LLM on every subsequent call, even though only the most recent tool results are relevant.

## Design

### 1. Heartbeat Pruning

**Location:** `PiCore.Session` — task completion handler

**Behavior:** When a heartbeat task completes and the response is HEARTBEAT_OK (strip_heartbeat_ok returns nil):
- Do NOT append the new messages (user prompt + tool calls + tool results + assistant response) to `state.messages`
- Do NOT persist to SessionStore
- Discard the entire exchange as if it never happened

When a heartbeat produces a meaningful response (strip_heartbeat_ok returns text):
- Append and persist as normal — the bot has something to say

**Implementation:** In `handle_info({ref, {:ok, new_messages}}, state)`, when `is_heartbeat` is true:
1. Check if the last assistant message would be suppressed by `strip_heartbeat_ok`
2. If suppressed: skip append + persist, just clear the task state
3. If not suppressed: append + persist as normal

The heartbeat user message was already added to `state.messages` in `do_prompt`. When pruning, we also need to remove it. Store the message count before the heartbeat started so we can roll back.

### 2. Tool Result Truncation in Transform

**Location:** `PiCore.Transform.transform_messages/3`

**Behavior:** Before sending messages to the LLM, truncate tool result content in older messages:
- Keep the last 4 messages with full content (covers the current tool call loop)
- For all older messages with role `toolResult`: truncate content to 200 chars + `\n... [truncated, was N chars]`
- Only affects the LLM payload — `state.messages` and disk storage keep full content
- User and assistant messages are not truncated (they're typically short)

**Why 4 messages:** A typical tool loop iteration produces: assistant (with tool_calls) → toolResult → assistant (with more tool_calls or final response) → toolResult. Keeping the last 4 ensures the current iteration's results are intact.

## Files to Modify

| File | Change |
|------|--------|
| `pi_core/lib/pi_core/session.ex` | Heartbeat pruning: check strip result before appending, roll back user message on prune |
| `pi_core/lib/pi_core/transform.ex` | Add tool result truncation for older messages |
