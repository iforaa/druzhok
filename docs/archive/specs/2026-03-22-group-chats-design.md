# Group Chat Support — Design Spec

## Goal

Enable Druzhok bot instances to participate in Telegram group chats with proper security (approval flow), trigger-based responses, and isolated per-chat sessions sharing a common workspace.

## DM Security — One-Time Pairing

### Flow

1. Unknown user messages the bot in DM
2. Bot generates an 8-character alphanumeric code (alphabet: `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`)
3. Bot replies: "Enter this code in the dashboard to activate: `XKRT-4NHP`"
4. Code appears in the dashboard under the instance → admin clicks Approve
5. User's `telegram_user_id` is saved as the permanent instance owner
6. All subsequent DM users get a static reply: "This bot is private."
7. One owner per instance — no second pairing possible
8. Pairing codes expire after 1 hour
9. Only one pending pairing at a time per instance — if a second unknown user messages while a code is pending, they get "This bot is not available."
10. If the same user who triggered the code messages again, bot re-sends the existing code

### Owner Identification

The owner is identified by numeric `telegram_user_id`, not username (usernames can change). Once approved, the `owner_telegram_id` is set on the instance record and cannot be changed from Telegram — only via the dashboard.

## Group Security — Dashboard Approval

### Flow

1. Bot receives a message from any group chat with a new `chat_id` not in `allowed_chats`
2. A pending entry is created with `chat_id`, `title`, `chat_type`
3. Bot is completely silent in non-approved groups, with one exception:
   - If someone @mentions the bot by username → bot replies once: "This bot requires approval. Ask the admin to approve this group in the dashboard."
   - This message is sent at most once per group (flag on the `allowed_chats` record)
4. Admin sees the pending group in the dashboard → clicks Approve or Reject
5. In approved groups, the bot responds according to trigger logic

### Bot Removed from Group

When the bot is removed from a group (detected via `my_chat_member` with status `kicked`/`left`, or detected when `getUpdates` returns a chat migration / kick event):
- Set `allowed_chats` status to `"removed"`
- Terminate the group's Session if running
- If the bot is re-added to the same group, it goes back to "pending" — requires re-approval

### Commands in Groups

`/reset` and `/abort` in groups are restricted to the instance owner only (matched by `owner_telegram_id`). Other group members cannot reset or abort the group session.

## Trigger Logic (Approved Groups Only)

The bot responds to a group message if ANY of these conditions are true:

1. **@mention** — message contains `@bot_username` (the Telegram bot username from `getMe`)
2. **Reply** — message is a reply to one of the bot's previous messages (check `reply_to_message.from.id == bot_id`)
3. **Name detection** — message text contains the bot's name (from `IDENTITY.md`), matched case-insensitively with word boundaries: `~r/\b#{Regex.escape(name)}\b/iu`

Otherwise, the message is ignored — not sent to the Session at all.

## Session Model

### Per-chat sessions

Each unique `chat_id` gets its own Session (GenServer with independent conversation history):

- DM with the owner → Session for `chat_id` = owner's user ID
- Group "Dev Team" → Session for `chat_id` = group's negative ID
- Group "Friends" → Session for another `chat_id`

Sessions are created on demand when the first triggered message arrives. They are supervised under a per-instance DynamicSupervisor (`Druzhok.Instance.SessionSup`).

### Session lifecycle

- **Created:** on first triggered message for a `chat_id`
- **Idle timeout:** sessions terminate after 2 hours of no messages (configurable). Conversation history is lost but workspace files survive.
- **Removed from group:** session terminated immediately
- **Group rejected:** session terminated, won't restart
- **Max sessions per instance:** 20 (configurable). If exceeded, oldest idle session is evicted.

### Shared workspace

All sessions for the same instance share the same workspace directory. `MEMORY.md`, `memory/*.md`, `inbox/`, and all other files are accessible from any session.

### System prompt differences

| File | DM | Group |
|------|-----|-------|
| AGENTS.md | Yes | Yes |
| SOUL.md | Yes | Yes |
| IDENTITY.md | Yes | Yes |
| BOOTSTRAP.md | Yes | Yes |
| USER.md | Yes | **No** |
| Group context | No | "You are in a group chat. Only respond when addressed. Keep replies concise." |

## Data Model

### `allowed_chats` table

| Column | Type | Description |
|--------|------|-------------|
| id | integer | Primary key |
| instance_name | string | FK to instance |
| chat_id | bigint | Telegram chat ID |
| chat_type | string | "private", "group", "supergroup" |
| title | string | Chat title (group name) or username |
| telegram_user_id | bigint | For DM: the owner's user ID. Null for groups |
| status | string | "pending", "approved", "rejected", "removed" |
| info_sent | boolean | Whether the "requires approval" message was sent (groups only) |
| timestamps | | |

Unique index on `(instance_name, chat_id)`.

### `pairing_codes` table

| Column | Type | Description |
|--------|------|-------------|
| id | integer | Primary key |
| instance_name | string | FK to instance |
| code | string | 8-char alphanumeric code |
| telegram_user_id | bigint | User who triggered the pairing |
| username | string | Telegram username (for display) |
| display_name | string | First + last name |
| expires_at | utc_datetime | Expiry (1 hour from creation) |
| timestamps | | |

Unique index on `(instance_name)` — only one pending code per instance.

### Instance record changes

Add `owner_telegram_id` (bigint, nullable) to the `instances` table. Set once during pairing approval.

## Component Changes

### Telegram Bot (`telegram.ex`)

`handle_update` becomes a routing layer:

```
message arrives
  → extract chat_type, chat_id, sender_id, text, file

  → is private chat?
    → has owner? → sender == owner? → dispatch to session(chat_id)
    → has owner? → sender != owner → reply "This bot is private."
    → no owner? → pending pairing exists for this user? → re-send code
    → no owner? → pending pairing for another user? → reply "Not available."
    → no owner? → no pending → generate code, reply with it

  → is group/supergroup?
    → lookup allowed_chats for this chat_id
    → approved? → check triggers → triggered? → dispatch to session(chat_id)
    → approved? → not triggered → ignore
    → pending/no record? → create pending if not exists → @mentioned? → reply approval msg (once) → ignore
    → rejected? → ignore
```

**Bot identity on init:** Call `getMe` to get `bot_id` and `bot_username`. Read `IDENTITY.md` to get `bot_name`. Cache all three in state.

### `on_delta` and `send_file_fn` — chat_id routing

The `on_delta` closure and `send_file_fn` closure need to know which `chat_id` to target. Since these closures are created once per instance (not per session), they cannot capture a specific `chat_id`.

Solution: the Telegram bot tracks `active_chat_id` — the chat_id of the message currently being processed. When `on_delta` fires, it sends to the Telegram process which knows the active chat. When `send_file_fn` fires, it calls `get_chat_id` on the Telegram process which returns the active chat.

This is already how it works — the Telegram bot's `state.chat_id` is set per incoming message. No change needed to the closures. The responses naturally go to the correct chat because `state.chat_id` is set before the session prompt is dispatched.

**However**, with parallel sessions, two sessions could race to set `state.chat_id`. This is mitigated by the fact that the Telegram bot processes messages sequentially in `handle_update` — it sets `chat_id` before dispatching, and the response comes back asynchronously. If two group sessions respond simultaneously, the Telegram bot needs to know which chat each response belongs to.

Fix: include `chat_id` in the `{:pi_response, ...}` message. Session stores its `chat_id` and passes it through `deliver_last_assistant`. The Telegram bot uses the `chat_id` from the response, not `state.chat_id`.

```elixir
# Session sends:
send(pid, {:pi_response, %{text: msg.content, prompt_id: ref, chat_id: state.chat_id}})

# Telegram receives:
def handle_info({:pi_response, %{text: text, chat_id: chat_id}}, state) do
  state = %{state | chat_id: chat_id}
  # ... finalize_response uses state.chat_id
end
```

Same for `{:pi_delta, chunk}` — include `chat_id`:
```elixir
on_delta = fn chunk, chat_id ->
  send(telegram_pid, {:pi_delta, chunk, chat_id})
end
```

Session passes `chat_id` to `on_delta` when calling it. The Telegram bot updates `state.chat_id` from the delta's `chat_id` before streaming.

### Instance.Sup

Replace the single `PiCore.Session` child with `Druzhok.Instance.SessionSup` (a DynamicSupervisor). The DM session is NOT started at boot — it's started on the first message from the approved owner, same as group sessions.

Session registration: `{instance_name, :session, chat_id}`.

### WorkspaceLoader

`PiCore.WorkspaceLoader.Default.load/2` reads the second argument:

```elixir
def load(workspace, opts) do
  files = if opts[:group], do: @files -- ["USER.md"], else: @files
  # ... rest stays the same
end
```

### Session changes

`PiCore.Session` needs:
- Store `chat_id` in state (passed via opts at init)
- Pass `chat_id` through `deliver_last_assistant` and `on_delta`
- Pass `%{group: true/false}` to workspace loader
- Idle timeout: `Process.send_after(self(), :idle_timeout, @idle_timeout_ms)` reset on every prompt. On timeout, `{:stop, :normal, state}`.

### Dashboard

Add a "Security" tab to the instance detail view:

- **Pairing section** (if no owner): shows pending pairing code, user info, Approve button
- **Owner section** (if owner set): shows owner display name + telegram_user_id
- **Groups section**: list of groups by status (approved/pending/rejected) with Approve/Reject buttons

## Event Broadcasting

New event types:
- `{type: :pairing_requested, code: "XKRT4NHP", user: "username"}`
- `{type: :pairing_approved, user: "username"}`
- `{type: :group_pending, title: "Dev Team", chat_id: -12345}`
- `{type: :group_approved, title: "Dev Team"}`
- `{type: :group_rejected, title: "Dev Team"}`
- `{type: :dm_rejected, reason: "not_owner"}`

## Tests

1. **DM from unknown user generates pairing code** — verify code format, stored in DB, bot replies with code
2. **Same user re-messaging gets same code** — no new code generated
3. **Second unknown user gets "not available"** — while first code is pending
4. **Pairing approval sets owner** — approve via InstanceManager, verify `owner_telegram_id` set
5. **DM from owner dispatches to session** — after pairing, verify messages reach session
6. **DM from non-owner gets rejection** — verify "This bot is private." reply
7. **Expired pairing code is cleaned up** — verify codes older than 1 hour are invalid
8. **Group message in unknown group creates pending record** — verify `allowed_chats` entry
9. **@mention in non-approved group replies with approval message once** — verify `info_sent` flag
10. **Trigger detection** — test @mention, reply-to-bot, and name detection separately
11. **Non-triggered group message is ignored** — no dispatch, no reply
12. **Group message in approved group dispatches to correct session** — verify per-chat session isolation
13. **USER.md not loaded in group sessions** — verify system prompt differs
14. **Commands restricted in groups** — `/reset` from non-owner ignored, from owner works
15. **Bot removed from group** — status changes to "removed", session terminated
16. **Re-added group goes back to pending** — verify re-approval required
17. **Session idle timeout** — verify session terminates after inactivity
18. **Response routed to correct chat_id** — two group sessions active, responses go to right groups

## Files Changed

- **New:** `apps/druzhok/priv/repo/migrations/XXXX_create_allowed_chats_and_pairing.exs`
- **New:** `apps/druzhok/lib/druzhok/allowed_chat.ex` — schema + queries
- **New:** `apps/druzhok/lib/druzhok/pairing.ex` — code generation, validation, approval
- **New:** `apps/druzhok/lib/druzhok/instance/session_sup.ex` — DynamicSupervisor for per-chat sessions
- **Modified:** `apps/druzhok/lib/druzhok/instance.ex` — add `owner_telegram_id` field
- **Modified:** `apps/druzhok/lib/druzhok/instance_manager.ex` — pairing + group approval APIs
- **Modified:** `apps/druzhok/lib/druzhok/agent/telegram.ex` — routing layer, triggers, pairing, group auth
- **Modified:** `apps/druzhok/lib/druzhok/instance/sup.ex` — SessionSup instead of single Session
- **Modified:** `apps/pi_core/lib/pi_core/session.ex` — chat_id in state, idle timeout, pass group flag to loader
- **Modified:** `apps/pi_core/lib/pi_core/workspace_loader.ex` — group context flag skips USER.md
- **Modified:** `apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex` — Security tab
- **New:** `apps/druzhok/test/druzhok/group_chat_test.exs`
