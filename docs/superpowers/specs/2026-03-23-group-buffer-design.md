# Group Chat Message Buffer

## Context

Druzhok v3 currently sends every group message to the LLM, even when the bot isn't addressed. The LLM returns `[NO_REPLY]` for most of these, wasting tokens. In an active group with 100 messages/hour, this means ~95 unnecessary LLM calls.

OpenClaw solves this with a buffer pattern: non-triggered messages are stored in memory and only sent to the LLM as context when the bot is actually addressed. This design adapts that pattern for Druzhok v3 with per-group configurability.

## Design

### 1. GroupBuffer Module

**Module**: `Druzhok.GroupBuffer`

ETS-backed buffer storing recent non-triggered messages per chat_id. Fast reads/writes, no DB overhead.

**Table**: `:druzhok_group_buffer` (created in application supervision tree)

**Entry format**: `{chat_id, [%{sender: String.t(), text: String.t(), timestamp: integer(), file: String.t() | nil}]}`

**Operations**:
- `push(chat_id, message, max_size)` — append to buffer, trim oldest if over max_size
- `flush(chat_id)` — return all buffered messages and clear the buffer
- `clear(chat_id)` — discard buffer without returning
- `size(chat_id)` — current buffer length

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
        └── not triggered? → push to buffer, done (no LLM call)
```

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

Added to the existing command parsing in `Router.parse_command/1` and handled in `telegram.ex`.

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
