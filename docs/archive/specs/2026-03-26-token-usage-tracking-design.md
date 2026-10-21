# Token Usage Tracking

**Date:** 2026-03-26
**Status:** Approved

## Problem

Both OpenAI and Anthropic APIs return exact token usage (`input_tokens`, `output_tokens`) in every response, but Druzhok's LLM clients discard this data. The `Client.Result` struct only has `content`, `tool_calls`, `reasoning`. There's no visibility into actual API consumption — only heuristic estimation via `byte_size / 4`.

## Goal

Capture actual token counts from every LLM call, store them in a database table, and display on a dashboard page for monitoring and optimization (identify expensive sessions, tool calls that consume too many tokens, models that are cost-inefficient).

## Design

### 1. Data Capture — Client.Result

Add `input_tokens` and `output_tokens` to `PiCore.LLM.Client.Result`:

```elixir
defstruct content: "", tool_calls: [], reasoning: "",
          input_tokens: 0, output_tokens: 0
```

### 2. OpenAI Client Changes

**Streaming** (`PiCore.LLM.OpenAI.stream_completion`):
- Add `stream_options: %{include_usage: true}` to the request body
- The final SSE chunk includes a `usage` object: `%{"prompt_tokens" => N, "completion_tokens" => N}`
- Parse this in `process_stream_event` and store on the Result accumulator

**Sync** (`PiCore.LLM.OpenAI.sync_completion`):
- Already decodes full response. Extract `data["usage"]["prompt_tokens"]` and `data["usage"]["completion_tokens"]`.

### 3. Anthropic Client Changes

**Streaming** (`PiCore.LLM.Anthropic.stream_completion`):
- `message_start` event contains `message.usage.input_tokens`
- `message_delta` event (type `message_delta`) contains `usage.output_tokens`
- Accumulate both on the Result during SSE parsing

**Sync** (`PiCore.LLM.Anthropic.sync_completion`):
- Already decodes full response. Extract `data["usage"]["input_tokens"]` and `data["usage"]["output_tokens"]`.

### 4. Loop Event Enhancement

`PiCore.Loop` already emits `:llm_done` events. Add token counts:

```elixir
emit(opts, %{
  type: :llm_done,
  iteration: iterations,
  elapsed_ms: elapsed,
  has_tool_calls: has_tools,
  content_length: content_len,
  reasoning_length: String.length(result.reasoning || ""),
  input_tokens: result.input_tokens,
  output_tokens: result.output_tokens
})
```

### 5. Database Table

New `llm_requests` table via Ecto migration:

| Column | Type | Notes |
|--------|------|-------|
| id | integer | auto PK |
| instance_name | string | which bot instance |
| chat_id | integer | which conversation (nullable for heartbeat) |
| model | string | model name |
| input_tokens | integer | from API response |
| output_tokens | integer | from API response |
| tool_calls_count | integer | number of tool calls in this response |
| elapsed_ms | integer | LLM call duration |
| iteration | integer | which loop iteration (0 = first call) |
| inserted_at | utc_datetime | timestamp |

Index on `(instance_name, inserted_at)` for dashboard queries.

### 6. Event Handler — Writing to DB

In `Druzhok.Instance.Sup`'s `on_event` closure, handle `:llm_done` events:

```elixir
if event[:type] == :llm_done do
  Druzhok.LlmRequest.log(%{
    instance_name: name,
    model: event[:model],
    input_tokens: event[:input_tokens] || 0,
    output_tokens: event[:output_tokens] || 0,
    tool_calls_count: if(event[:has_tool_calls], do: 1, else: 0),
    elapsed_ms: event[:elapsed_ms],
    iteration: event[:iteration]
  })
end
```

The `chat_id` is not directly available in the `on_event` closure (it fires from a Task inside Loop). We'll pass it through the event by including it in Loop's opts context, or set it to nil and rely on `instance_name` + `inserted_at` for correlation.

Note: `tool_calls_count` counts whether this response had tool calls. The actual number of tool calls per response can be derived from the `tool_calls` list length. We'll pass the count from Loop:

```elixir
tool_calls_count: length(result.tool_calls || [])
```

### 7. Dashboard Page

New LiveView at `/usage` route, linked from the main dashboard sidebar/nav.

**Summary section** (top):
- Cards showing: total tokens today, total tokens this week, per-instance breakdown
- Top models by token consumption (simple table)

**Request log** (bottom):
- Paginated table with columns: time, instance, model, input tokens, output tokens, total, tool calls, elapsed ms
- Filters: instance dropdown, date range picker, model dropdown
- Default: last 24 hours, all instances
- Sortable by any column

### 8. LlmRequest Schema

New Ecto schema `Druzhok.LlmRequest`:

```elixir
schema "llm_requests" do
  field :instance_name, :string
  field :chat_id, :integer
  field :model, :string
  field :input_tokens, :integer, default: 0
  field :output_tokens, :integer, default: 0
  field :tool_calls_count, :integer, default: 0
  field :elapsed_ms, :integer
  field :iteration, :integer, default: 0
  timestamps(updated_at: false)
end
```

Query helpers:
- `today(instance_name)` — aggregate tokens for today
- `by_date_range(instance_name, from, to)` — for dashboard filters
- `recent(limit)` — for the request log

DB writes are fire-and-forget (async Task or cast) to avoid blocking the LLM response path.

## Files to Modify

| File | Change |
|------|--------|
| `pi_core/lib/pi_core/llm/client.ex` | Add `input_tokens`, `output_tokens` to Result struct |
| `pi_core/lib/pi_core/llm/openai.ex` | Extract usage from streaming + sync responses |
| `pi_core/lib/pi_core/llm/anthropic.ex` | Extract usage from streaming + sync responses |
| `pi_core/lib/pi_core/loop.ex` | Add token counts + tool_calls_count to `:llm_done` event |
| `druzhok/lib/druzhok/llm_request.ex` | New Ecto schema + query helpers |
| `druzhok/priv/repo/migrations/` | New migration for `llm_requests` table |
| `druzhok/lib/druzhok/instance/sup.ex` | Handle `:llm_done` in on_event, write to DB |
| `druzhok_web/lib/live/usage_live.ex` | New LiveView for usage dashboard |
| `druzhok_web/lib/router.ex` | Add `/usage` route |

## Testing

- **Unit**: Verify OpenAI and Anthropic clients populate `input_tokens`/`output_tokens` on Result
- **Integration**: Send a message, verify `llm_requests` row is created with non-zero token counts
- **Dashboard**: Load `/usage`, verify summary cards and request log render with data
