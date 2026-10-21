# Tool Status Messages, Typing Refresh & Group Message Persistence

**Date:** 2026-03-26
**Status:** Approved

## Problem

Three related issues degrade the bot's user experience:

1. **Typing indicator dies after 5s** — Telegram's `sendChatAction("typing")` expires after ~5 seconds. During tool execution (30-60s+), the bot appears dead.
2. **Bot goes silent during tool calls** — no status messages about what tools are running. User has no idea if the bot is searching the web, writing a file, or stuck.
3. **Group chat context loss** — `GroupBuffer` uses ETS (in-memory only). On app restart, session crash, or idle timeout, buffered messages are lost. Bot says "контекст не дошёл" because it genuinely doesn't have the earlier messages.

## Design

### 1. Tool Status Messages

#### Event Flow

```
PiCore.Loop (emits :tool_call event with tool name + args)
  → on_event callback
    → Druzhok.Instance.Sup routes to Telegram agent
      → Telegram agent edits streaming message with status text
      → Starts typing refresh timer (4s interval)
      → On next :pi_delta or :pi_response → cancels timer
```

#### Status Text Mapping

`Druzhok.Agent.ToolStatus` module — maps tool names to Russian status strings:

| Tool | Status |
|------|--------|
| `web_fetch` | "Ищу в интернете..." |
| `bash` | "Выполняю команду..." |
| `read` | "Читаю файл..." |
| `write` | "Пишу файл..." |
| `edit` | "Редактирую файл..." |
| `grep` | "Ищу в файлах..." |
| `find` | "Ищу в файлах..." |
| `memory_search` | "Ищу в памяти..." |
| `memory_write` | "Сохраняю в память..." |
| `generate_image` | "Генерирую изображение..." |
| `send_file` | "Отправляю файл..." |
| fallback | "Работаю..." |

#### Message Behavior

- Status is **edited into the current streaming message** if one exists (Telegram `editMessageText`)
- If no streaming message exists yet, **send a new message** and track its `message_id`
- When the LLM produces text after the tool call, the streaming delta overwrites/edits the status message — the status is naturally replaced
- Status messages are brief and don't accumulate — each new tool call replaces the previous status

#### Prompt-Level Narration

Add to system prompt instruction:
- "Before using tools, briefly explain what you're about to do and why"
- "If a tool fails or returns an error, explain what happened and what you'll try next"

This goes into the default AGENTS.md template or the system prompt builder in `PiCore.PromptBudget`.

#### Error Explanation

When `:tool_result` has `is_error: true`, the LLM already sees the error in its context. The prompt instruction ensures it explains the error to the user rather than silently retrying or giving up.

### 2. Typing Indicator Refresh

#### Implementation

Add a typing refresh mechanism to `Druzhok.Agent.Telegram`:

- **Start:** When a `:tool_call` event is received (via `handle_info({:pi_tool_status, ...})`), start a recurring timer that sends `API.send_chat_action(token, chat_id)` every 4 seconds
- **Stop:** Cancel the timer when:
  - A `:pi_delta` chunk arrives (LLM is streaming text)
  - A `:pi_response` arrives (response complete)
  - A new `:tool_call` arrives (resets the timer)
- **Storage:** Store `typing_timer` ref in the Telegram agent state

#### Timer Details

- Use `Process.send_after(self(), :refresh_typing, 4_000)` in a loop
- On `:refresh_typing` → send chat action + schedule next
- Cancel via `Process.cancel_timer/1` when done

### 3. Group Message Persistence

#### Current Architecture (broken)

```
Non-triggered msg → GroupBuffer (ETS, volatile) → lost on restart
Triggered msg → flush ETS → format as inline text → LLM prompt
```

Problems:
- ETS is in-memory only — lost on app restart
- Buffered messages are formatted as text, never saved as Message objects
- Session idle timeout (2h) kills session; new session has no buffer context
- Crash during tool execution loses buffered context

#### New Architecture

```
Any group msg → SessionStore.append (disk) + Session.messages (memory)
Triggered msg → Session.prompt (history already loaded from session)
```

Every group message is immediately persisted to the session's JSONL file on disk, regardless of whether it triggers the bot. When the bot IS triggered, the full conversation history is already in the session.

#### Changes

**`Druzhok.Agent.Telegram`:**

- `process_group_message_buffer` when NOT triggered:
  - Instead of `GroupBuffer.push(...)`, append the message to the session via `SessionStore.append(workspace, chat_id, user_msg)`
  - Also push to the in-memory session if it exists: look up the session in Registry and add the message to its state
- `process_group_message_buffer` when triggered:
  - No more `GroupBuffer.flush` — the messages are already in the session
  - Just call `dispatch_prompt(prompt, chat_id, true, state)` with only the triggering message
  - The session already has the full history loaded

**`PiCore.Session`:**

- Add `push_message(pid, text)` — appends a user message to session history without triggering an LLM call. This is for non-triggered group messages that should be recorded but not responded to.
- The message gets added to `state.messages` and persisted via `SessionStore.append`
- If the session doesn't exist yet, `SessionStore.append` writes directly to disk — the session will load it on next startup

**`Druzhok.GroupBuffer`:**
- Deprecated. Can be removed once the new flow is validated.
- Remove ETS table creation from `Druzhok.Application`

#### Session Lifecycle

- Session starts → loads ALL messages from `SessionStore` (includes non-triggered group messages)
- Non-triggered message arrives → `push_message` adds to session + disk
- Triggered message arrives → `prompt` runs LLM with full history
- Session idle timeout → exits, but all messages are on disk
- Session restarts → loads from disk, full context restored

### 4. WebSocket Support

For the web dashboard chat channel:

- Route `:pi_tool_status` events to the WebSocket channel
- Channel pushes `tool_status` event with `%{tool: name, status: text}` to the client
- Client can display a status indicator in the chat UI

## Files to Modify

| File | Change |
|------|--------|
| `pi_core/lib/pi_core/session.ex` | Add `push_message/2` for non-triggered group messages |
| `pi_core/lib/pi_core/loop.ex` | No changes — already emits `:tool_call` events |
| `druzhok/lib/druzhok/instance/sup.ex` | Route `:tool_call` events to Telegram agent as `:pi_tool_status` |
| `druzhok/lib/druzhok/agent/telegram.ex` | Handle `:pi_tool_status`, typing refresh timer, status message editing |
| `druzhok/lib/druzhok/agent/tool_status.ex` | New module — tool name → status text mapping |
| `druzhok/lib/druzhok/group_buffer.ex` | Deprecated/removed |
| `druzhok/lib/druzhok/application.ex` | Remove ETS table creation for group buffer |
| `druzhok_web/lib/channels/chat_channel.ex` | Handle `:pi_tool_status` events, push to client |
| System prompt / AGENTS.md | Add tool narration + error explanation instructions |

## Testing Strategy

- **Typing refresh**: Send a message that triggers `web_fetch` → verify multiple `sendChatAction` calls during execution
- **Tool status**: Trigger tool calls → verify status messages appear and are replaced by actual response
- **Group persistence**: Send non-triggered messages → restart app → send triggered message → verify bot has context from before restart
- **Error handling**: Trigger a tool that fails (e.g., fetch unreachable URL) → verify bot explains the error
