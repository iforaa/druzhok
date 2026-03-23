# Group Chat Message Buffer

## Context

Druzhok v3 currently sends every group message to the LLM, even when the bot isn't addressed. The LLM returns `[NO_REPLY]` for most of these, wasting tokens. In an active group with 100 messages/hour, this means ~95 unnecessary LLM calls.

OpenClaw solves this with a buffer pattern: non-triggered messages are stored in memory and only sent to the LLM as context when the bot is actually addressed. This design adapts that pattern for Druzhok v3 with per-group configurability.

## Design

### 1. GroupBuffer Module

**Module**: `Druzhok.GroupBuffer`

ETS-backed buffer storing recent non-triggered messages per instance+chat. Fast reads/writes, no DB overhead.

**Table**: `:druzhok_group_buffer` — created in `Druzhok.Application.start/2` via `:ets.new(:druzhok_group_buffer, [:set, :public, :named_table])`. Public access so any process can read/write without a GenServer bottleneck. Owned by the application master process (lives for the duration of the app).

**Key**: `{instance_name, chat_id}` — multi-tenant safe. Different bot instances sharing a chat_id get separate buffers.

**Entry format**: `{{instance_name, chat_id}, [%{sender: String.t(), text: String.t(), timestamp: integer(), file: String.t() | nil}]}`

Timestamps use `System.os_time(:millisecond)` for consistency with the rest of the codebase.

**Operations**:
- `push(instance_name, chat_id, message, max_size)` — append to buffer, trim oldest if over max_size
- `flush(instance_name, chat_id)` — return all buffered messages and clear the buffer
- `clear(instance_name, chat_id)` — discard buffer without returning
- `size(instance_name, chat_id)` — current buffer length

**Data loss on restart**: ETS is in-memory. If the node restarts, buffered messages are lost. This is acceptable — the buffer is ephemeral context, not critical data. The bot simply has less conversational context on its first trigger after restart.

**Cleanup**: `clear/2` is called when a group is rejected or removed (in `AllowedChat.reject/2` and `mark_removed/2` flows). No periodic cleanup needed — ETS entries are small and bounded by `buffer_size`.

**File handling in buffer mode**: Non-triggered messages do NOT save files to workspace. Only the text reference (e.g., "[photo]", "[document: filename]") is stored in the buffer. Files are only saved when the bot is actually triggered and processes the message. This prevents busy groups from filling the workspace inbox.

**Flush format**: When the bot is triggered, buffered messages are formatted as a context block prepended to the prompt:

```
[Сообщения в чате с момента твоего последнего ответа — для контекста]
[Иван]: привет всем
[Мария]: кто идёт на обед?
[Иван]: я иду

[Текущее сообщение — ответь на него]
[Мария]: @bot что думаешь?
```

### 2. Group Activation Modes

Two modes per group, stored in `allowed_chats.activation` (default `"buffer"`).

**`buffer` mode (default)**:
- Non-triggered messages pushed to GroupBuffer, no LLM call
- Triggered messages flush buffer as context prefix, single LLM call
- Cost: 1 LLM call per trigger event

**`always` mode**:
- Every message sent to LLM (current behavior preserved)
- LLM uses `[NO_REPLY]` to stay silent when appropriate
- AGENTS.md instructions guide when to speak up
- Cost: 1 LLM call per message

**Mode switching**:
- Dashboard: dropdown per allowed chat in security tab
- Bot command: `/mode buffer` or `/mode always` (owner only)
- Updates `allowed_chats.activation` in DB

**Message flow in telegram.ex**:

```
Group message arrives (approved chat)
  ├── activation == "always" → send to LLM (current behavior)
  └── activation == "buffer"
        ├── triggered? → flush buffer + prepend as context + send to LLM
        └── not triggered? → push to buffer + emit event (for dashboard log) + done (no LLM call)
```

**Event emission**: In buffer mode, non-triggered messages still emit a `:user_message` event so the dashboard event log shows group activity. The event just doesn't trigger an LLM call.

**Messages arriving between flush and LLM response**: Go into a fresh buffer and will be included in the next trigger. This is expected behavior — the bot sees a consistent snapshot at trigger time.

### 3. Database Changes

**Migration**: Add to `allowed_chats` table:

| Column | Type | Default | Purpose |
|--------|------|---------|---------|
| `activation` | string | `"buffer"` | Group activation mode |
| `buffer_size` | integer | 50 | Max messages to buffer per group |

**AllowedChat schema**: Add fields and update changeset.

### 4. Dashboard Changes

Extend the existing SecurityTab (allowed chats management) with two fields per chat row:
- Activation mode dropdown (`buffer` / `always`)
- Buffer size number input

No new pages needed.

### 5. Bot Command

`/mode buffer` or `/mode always` — owner-only command in groups. Updates `allowed_chats.activation` via DB. Confirms with a message like "Switched to buffer mode."

**Command parsing**: `Router.parse_command/1` is extended to return `{:command, "mode", arg}` for commands with arguments. The existing return format `{:command, name}` is preserved for argument-less commands. Call sites in `telegram.ex` are updated to pattern match both formats.

**Validation**: `buffer_size` in the dashboard is validated to be between 1 and 500. Values outside this range are clamped.

## Modified Modules

| Module | Changes |
|--------|---------|
| `Druzhok.GroupBuffer` | New module — ETS-backed message buffer |
| `Druzhok.Agent.Telegram` | Route non-triggered messages to buffer in buffer mode; flush on trigger |
| `Druzhok.Agent.Router` | Add `/mode` command parsing |
| `Druzhok.AllowedChat` | Add `activation`, `buffer_size` fields |
| `DruzhokWebWeb.SecurityTab` | Add activation/buffer_size controls per chat |
| Migration | Add columns to `allowed_chats` |

## New Modules

| Module | Purpose |
|--------|---------|
| `Druzhok.GroupBuffer` | ETS buffer for non-triggered group messages |

## Token Impact

In buffer mode, a group with 100 messages between triggers goes from 100 LLM calls to 1 LLM call with ~50 messages of context. The context cost of the buffered messages is a fraction of 100 separate LLM round-trips (no system prompt repeated, no tool definitions repeated, single response generation).

**Estimated savings**: 90-98% reduction in LLM calls for buffer-mode groups.
