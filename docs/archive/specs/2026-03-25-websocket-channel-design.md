# WebSocket Channel for App Communication

## Context

Druzhok v3 currently only supports Telegram as a channel. The user is building a React Native app that needs to communicate with the same bot instances. The app connects via WebSocket (Phoenix Channel), shares the same workspace/memory/skills as Telegram, but has independent conversation sessions.

## Design

### 1. Phoenix Channel

A new `ChatChannel` in druzhok_web. The app connects via WebSocket and communicates through Phoenix Channel events.

**Connection:**
```
ws://server:4000/socket/chat
  → join "chat:lobby" with %{api_key: "dk_xxxxx"}
  → server validates key against instances table
  → assigns instance_name to socket
```

**App sends:**

| Event | Payload | Description |
|-------|---------|-------------|
| `message` | `%{text: "hello", chat_id: "app_123"}` | Send a message |
| `reset` | `%{chat_id: "app_123"}` | Reset session |
| `abort` | `%{chat_id: "app_123"}` | Abort current generation |

**App receives:**

| Event | Payload | Description |
|-------|---------|-------------|
| `delta` | `%{text: "chunk", chat_id: "app_123"}` | Streaming token |
| `response` | `%{text: "full text", chat_id: "app_123"}` | Final response |
| `error` | `%{text: "reason", chat_id: "app_123"}` | Error |

Non-streaming mode: app ignores `delta` events, waits for `response`. No server flag needed.

**Channel internals:**
- On `message` event: looks up or starts `PiCore.Session` for the chat_id (same as Telegram's `dispatch_prompt`)
- Session sends `{:pi_delta, chunk, chat_id}` and `{:pi_response, %{text: text, chat_id: chat_id}}` back to the Channel process
- Channel pushes events to the WebSocket client

Chat IDs from the app are separate from Telegram chat IDs — sessions are independent but share workspace.

### 2. Instance API Key

**New field on `instances` table:**
- `api_key` (string, nullable) — format: `dk_` + 32 random hex chars

**Dashboard:**
- "API Key" section on instance page
- Generate/regenerate button
- Key shown once after generation (masked after)

**Auth flow:**
- App sends `api_key` when joining the channel
- Channel looks up instance by `api_key`
- If no match, join is rejected

Both Telegram and WebSocket can be active simultaneously on the same instance. Telegram uses `telegram_token`, WebSocket uses `api_key`. Independent.

### 3. Socket Setup

**New Phoenix Socket** at `/socket/chat`:
```elixir
socket "/socket/chat", DruzhokWebWeb.ChatSocket,
  websocket: [connect_info: [:peer_data]]
```

The socket handles connection-level concerns. The channel handles message-level concerns.

## New Modules

| Module | App | Purpose |
|--------|-----|---------|
| `DruzhokWebWeb.ChatSocket` | druzhok_web | WebSocket endpoint, connection handling |
| `DruzhokWebWeb.ChatChannel` | druzhok_web | Channel for chat messages, dispatches to Session |

## Modified Modules

| Module | Changes |
|--------|---------|
| `Druzhok.Instance` | Add `api_key` field |
| `DruzhokWebWeb.Endpoint` | Add socket route |
| `DruzhokWebWeb.DashboardLive` | Add API key generation UI |
| Migration | Add `api_key` to `instances` table |

## Migration

```elixir
alter table(:instances) do
  add :api_key, :string
end

create unique_index(:instances, [:api_key])
```
