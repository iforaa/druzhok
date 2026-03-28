# User Approval System Design

Allow bot owners to approve Telegram users directly from the dashboard, without CLI access or knowing Telegram IDs.

## Flow

1. User creates bot instance, starts it from dashboard
2. Someone messages the bot on Telegram
3. Bot replies with approval message containing the sender's Telegram ID
4. The person copies the ID and pastes it into the dashboard (Settings > Security)
5. Orchestrator writes the ID to the runtime's config file on disk
6. Runtime picks up the change (ZeroClaw watches config, PicoClaw needs restart)
7. User sends message again — bot responds

## Runtime Adapter Callbacks

Add three new callbacks to `Druzhok.Runtime` behaviour:

```elixir
@callback read_allowed_users(data_root :: String.t()) :: [String.t()]
@callback add_allowed_user(data_root :: String.t(), user_id :: String.t()) :: :ok | {:error, term()}
@callback remove_allowed_user(data_root :: String.t(), user_id :: String.t()) :: :ok | {:error, term()}
```

### ZeroClaw Implementation

Read/write `.zeroclaw/config.toml`:
- Parse TOML, find `channels_config.telegram.allowed_users` array
- Add/remove user ID, write file back
- ZeroClaw daemon watches config file — no restart needed

### PicoClaw Implementation

PicoClaw uses env vars for `allow_from`, not config files. Two options:
- Write a `config.json` that PicoClaw reads on reload, POST `/reload`
- Or restart the container with updated env var

For now: restart container (simpler, PicoClaw doesn't hot-reload allowlists).

## Dashboard UI

In the Settings tab, after the existing form fields, add a Security subsection:

```
─── Security ───────────────────────────────

Approved Telegram Users
┌─────────────────────────────────────────┐
│ 281775258                       [Remove] │
│ 601956                          [Remove] │
└─────────────────────────────────────────┘

┌──────────────────────────┐ [Approve]
│ Paste user ID here       │
└──────────────────────────┘
Paste the number from the bot's approval message,
or the full "zeroclaw channel bind-telegram 12345" command.

Group Behavior
  ☑ Mention only (respond only when @mentioned in groups)
```

### Input Parsing

The input field accepts:
- Raw ID: `281775258`
- Full command: `zeroclaw channel bind-telegram 281775258`
- With @: `@username` (stored as-is)

Parse with regex: extract the last number or the text after `bind-telegram`.

### mention_only Toggle

Write `mention_only = true/false` to the same config.toml alongside allowed_users. Applies to group chats only — DMs always respond.

## File Map

| Action | File |
|--------|------|
| Modify | `lib/druzhok/runtime.ex` — add 3 new callbacks |
| Modify | `lib/druzhok/runtime/zero_claw.ex` — implement TOML read/write |
| Modify | `lib/druzhok/runtime/pico_claw.ex` — implement restart-based approach |
| Modify | `dashboard_live.ex` — add Security subsection to Settings tab |

## What's NOT in scope

- Multi-user dashboard (only admin manages all instances)
- Group-level approval (neither runtime supports it — user approval covers groups)
- Pairing code flow via dashboard (user pastes ID directly, simpler)
