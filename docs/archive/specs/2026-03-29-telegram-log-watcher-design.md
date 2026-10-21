# Telegram Log Watcher — Unauthorized User Detection & Pairing

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this spec.

**Goal:** Detect unauthorized Telegram users from runtime container logs, send them a localized message with their user ID, and create a pairing request on the dashboard for the owner to approve.

**Architecture:** No proxy, no webhook, no runtime patches. Runtimes own Telegram natively. The Elixir app tails container logs via `docker logs -f`, parses rejection lines using runtime-specific patterns, and sends supplementary Telegram messages via the bot's token.

---

## Components

### 1. LogWatcher GenServer

One GenServer per running instance. Lifecycle:

- **Started** by `post_start` (inside the async Task) after PicoClaw/ZeroClaw is healthy
- **Stopped** by `BotManager.stop/1` before container removal
- **Supervised** under `Druzhok.InstanceDynSup` (DynamicSupervisor) with instance name in the Registry

Internally:
- Opens a port via `System.cmd` or `Port.open` running `docker logs -f --since=5s <container_name>`
- Reads lines from stdout/stderr
- Passes each line to `runtime.parse_log_rejection(line)`
- On `{:rejected, user_id}` → triggers pairing flow
- Tracks `last_rejection_seen_at` timestamp for format-change detection

Named via `{:via, Registry, {Druzhok.Registry, {instance_name, :log_watcher}}}`.

### 2. Runtime Callback: `parse_log_rejection/1`

Added to `Druzhok.Runtime` behaviour:

```elixir
@callback parse_log_rejection(line :: String.t()) :: {:rejected, user_id :: String.t()} | :ignore
```

**PicoClaw** pattern (DEBUG level):
```
Message rejected by allowlist user_id=123456
```
Regex: `~r/rejected by allowlist.*user_id=(\S+)/`

**ZeroClaw** pattern (WARN level):
```
Telegram: ignoring message from unauthorized user: username=foo, sender_id=123456
```
Regex: `~r/ignoring message from unauthorized user.*sender_id=(\S+)/`

Both return `{:rejected, "123456"}` on match, `:ignore` on everything else. If the runtime updates and changes the log format, the regex silently stops matching — no crashes, no false positives.

### 3. Format-Change Detection

The LogWatcher tracks `last_rejection_seen_at`. A periodic check (every 6 hours) evaluates:

- If the instance is running AND the log watcher has been active for >24 hours AND `last_rejection_seen_at` is nil (never matched anything):
  - Insert a warning into `crash_logs` table: "LogWatcher for #{instance_name}: no rejection patterns matched in 24h — runtime log format may have changed"
  - This surfaces on the Errors tab in the dashboard
  - Only fire this warning once (track with a flag, reset when a match is found)

This avoids false alarms for new instances that haven't received any unauthorized messages yet — the warning only fires after 24h of zero matches.

### 4. Pairing Request (Deduplication)

On rejection detection:

1. Check if a pending pairing request already exists for `{instance_name, user_id}` — if yes, skip
2. Create pairing request in DB: `Druzhok.Pairing.create_request(instance_name, user_id)`
3. Broadcast event to dashboard: `Druzhok.Events.broadcast(instance_name, %{type: :pairing_request, user_id: user_id})`

The existing `pairing_requests` table and dashboard UI handle display and approval. If the table doesn't exist yet for this purpose, create it with: `instance_name`, `telegram_user_id`, `status` (pending/approved/rejected), `inserted_at`.

### 5. Telegram Notification to Rejected User

After creating the pairing request, send a Telegram message to the user:

```elixir
Druzhok.TelegramApi.send_message(bot_token, user_id, rejection_text)
```

Uses the instance's bot token. Sent via `Druzhok.Finch` (through VPN proxy, same as all outbound HTTP).

**Message content** — localized using the instance's `language` field:

- **ru**: `"Этот бот приватный. Ваш Telegram ID: #{user_id}. Запрос на доступ отправлен владельцу бота."`
- **en**: `"This bot is private. Your Telegram ID: #{user_id}. Access request has been sent to the bot owner."`

Per-instance override: `instances.reject_message` field (nullable). If set, use it instead of the i18n default. The placeholder `%{user_id}` is interpolated.

Global default comes from i18n, per-instance override from the DB field.

### 6. Approval Flow

When owner clicks Approve on the dashboard:

1. Add user to runtime's `allow_from` (existing `runtime.add_allowed_user/2`)
2. Reload runtime config (existing for PicoClaw; ZeroClaw picks up config.toml changes)
3. Send welcome message via Telegram API to the approved user

**Welcome message** — localized:

- **ru**: `"Доступ одобрен! Можете начать общение с ботом."`
- **en**: `"Access approved! You can now start chatting with the bot."`

Per-instance override: `instances.welcome_message` field (nullable). Same interpolation rules.

### 7. Group Chat Handling

Groups are handled identically to DMs:
- Runtime rejects unauthorized group message → logged
- LogWatcher detects rejection → creates pairing request with the group's chat_id
- Sends rejection message to the group
- Owner approves → group added to allowed chats (existing `AllowedChat` system)

The `parse_log_rejection` callback returns the user/chat ID regardless of whether it's a DM or group. The pairing system already distinguishes between users and groups.

---

## Database Changes

Add two nullable text columns to `instances`:

```sql
ALTER TABLE instances ADD COLUMN reject_message TEXT;
ALTER TABLE instances ADD COLUMN welcome_message TEXT;
```

No new tables needed — reuse existing `pairing_requests` or `allowed_chats` tables.

---

## New Modules

| Module | Purpose | LOC estimate |
|--------|---------|-------------|
| `Druzhok.LogWatcher` | GenServer, tails docker logs, delegates parsing to runtime | ~80 |
| `Druzhok.TelegramApi` | `send_message/3`, `set_webhook/3`, `delete_webhook/2` | ~40 |
| Runtime callback additions | `parse_log_rejection/1` in PicoClaw + ZeroClaw | ~10 each |

**Total new code: ~140 LOC**

---

## Integration Points

- `BotManager.start/1` → `post_start` starts LogWatcher
- `BotManager.stop/1` → stops LogWatcher
- `Dashboard` → shows pairing requests (existing), approve sends welcome message (new)
- `Runtime.parse_log_rejection/1` → new behaviour callback
- `Druzhok.ErrorLogger` / `crash_logs` → format-change warnings surface on Errors tab

---

## What This Does NOT Do

- No Telegram webhook or polling from Elixir
- No message proxying or forwarding
- No runtime patching
- No interference with how runtimes handle authorized messages
- No media handling — text messages only for rejection/welcome notifications

---

## PicoClaw allow_from Behavior

PicoClaw treats an empty `allow_from` list as "allow everyone". The adapter currently sets `allow_from: ["__closed__"]` as a sentinel value to block all users by default. This sentinel is preserved — the log watcher depends on PicoClaw actually rejecting unauthorized users.

When the first user is approved, `allow_from` becomes `["__closed__", "123456"]`. The `__closed__` entry never matches a real user, so it's harmless. Alternatively, it can be removed when the first real user is added.
