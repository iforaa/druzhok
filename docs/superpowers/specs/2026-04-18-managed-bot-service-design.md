# Managed Bot Service

Date: 2026-04-18
Status: Draft — pending user review

## Problem

Users who want their own AI bot currently need the operator (Igor) to manually create an instance via the druzhok dashboard — set a Telegram token, pick a model, configure settings, start the container. This doesn't scale beyond friends.

Telegram's Bot API 9.6 (April 2026) introduced Managed Bots: a manager bot can request users to create new bots through Telegram's native UI, then receive the new bot's token and control it programmatically. This enables a self-service onboarding flow where users create their own bots in 30 seconds without touching the dashboard.

## Scope

A manager bot GenServer inside druzhok's Phoenix app that:

- Runs a conversational onboarding flow via Telegram inline keyboards (name → personality → language → create)
- Generates `t.me/newbot/...` deep links that open Telegram's native bot creation UI
- Handles `managed_bot` updates when a bot is created
- Auto-provisions a hermes instance (container, config, auto-pairing)
- Enforces a 2-bot-per-user limit

**In scope:**
- ManagerBot GenServer with long-polling against the Telegram Bot API
- Per-user conversation state machine (5 steps)
- Username generation (slugify name + 4-char random suffix)
- Provisioning pipeline: `getManagedBotToken` → `BotManager.create` → apply personality → auto-pair creator → start container → send confirmation
- 2-bot-per-user hard limit
- Manager bot token stored as a druzhok Setting

**Out of scope (deferred):**
- User-facing dashboard / per-user accounts
- Mini App for richer onboarding
- Billing / payment
- Bot deletion via the manager bot (admin-only from druzhok dashboard)
- Custom SOUL.md free-text (preset personalities only)
- Trigger word setup during onboarding (configurable later via admin dashboard)
- Model selection during onboarding (default model applied automatically)

## Architecture

```
┌──────────────────────────────────────────────────┐
│  Druzhok Phoenix App (BEAM)                       │
│                                                    │
│  ┌─────────────────┐    ┌──────────────────────┐  │
│  │ ManagerBot       │    │ BotManager            │  │
│  │ (GenServer)      │───▶│ .create(name, opts)   │  │
│  │                  │    │ .start(name)          │  │
│  │ • long-polling   │    └──────────────────────┘  │
│  │ • state machine  │                              │
│  │ • inline kbd     │    ┌──────────────────────┐  │
│  │ • user sessions  │    │ Instance DB           │  │
│  │ • 2-bot limit    │    │ + owner_telegram_id   │  │
│  └─────────────────┘    └──────────────────────┘  │
│           │                        │               │
│           │ getManagedBotToken     │ docker run     │
│           ▼                        ▼               │
│     Telegram Bot API        hermes container       │
└──────────────────────────────────────────────────┘
```

### ManagerBot GenServer

Single supervised process inside druzhok's application supervision tree. Responsibilities:

- **Long-polling** the Telegram Bot API using the manager bot's own token (stored in `Druzhok.Settings` as `manager_bot_token`). Uses `Finch` HTTP client (already available in druzhok).
- **Conversation state** stored in a `%{user_id => %{step, name, personality, language, started_at}}` map. Entries expire after 10 minutes of inactivity (cleanup on each poll tick).
- **Inline keyboard messages** for each onboarding step — no free-text input except the bot name.
- **Username generation**: transliterate name to ASCII, slugify, append 4-char hex suffix, append `_bot`. If the user edits the username in Telegram's native UI, the actual value from `ManagedBotUpdated.bot.username` is used.
- **`managed_bot` update handling**: receives the update when the user confirms bot creation in Telegram's UI, triggers the provisioning pipeline.
- **Rate limiting**: 2-bot-per-user hard cap checked before generating the creation link. Count: `SELECT COUNT(*) FROM instances WHERE owner_telegram_id = ? AND active = true`.

### Onboarding flow

```
User opens @DruzhokManagerBot, sends /start or any message

Step 1 — :name
  Bot: "Привет! Я создам тебе персонального AI-бота. Как его назвать?"
  User: types free text (e.g. "Вася")

Step 2 — :personality
  Bot: "Характер бота:"
       [Помощник] [Кавай] [Пират] [Нуар] [Философ]
       [Шекспир] [Сёрфер] [Хайп]  [Ещё...]
  User: taps a button

Step 3 — :language
  Bot: "Язык:"
       [Русский] [English]
  User: taps a button

Step 4 — :confirm
  Bot: "Отлично! Нажми кнопку — Telegram предложит создать бота:"
       [🤖 Создать «Вася»]
       ↳ button URL: t.me/newbot/DruzhokManagerBot/vasya_a7f3_bot?name=Вася
  User: taps → Telegram native creation UI → confirms

Step 5 — :done (triggered by managed_bot update)
  Bot: "✅ Бот @vasya_a7f3_bot создан и запущен!
        → Написать боту: t.me/vasya_a7f3_bot"
```

State machine: `:idle → :name → :personality → :language → :confirm → :done`. Each step validates input and loops back with a hint on invalid input. Conversation state expires after 10 minutes.

### Provisioning pipeline

Triggered when the `managed_bot` update arrives (step 4 → 5 transition):

1. Extract `bot_user_id` from `ManagedBotUpdated.bot.id` and `creator_user_id` from `ManagedBotUpdated.user.id`.
2. Look up the conversation state for `creator_user_id` to get `name`, `personality`, `language`.
3. Call Telegram API `getManagedBotToken(user_id: bot_user_id)` → receive the bot's token.
4. Derive the instance name from the bot's actual username (from the update, not the suggested one): strip trailing `_bot`, e.g. `vasya_a7f3`.
5. Call `BotManager.create(instance_name, %{telegram_token: token, model: default_model, owner_telegram_id: creator_user_id, language: language, bot_runtime: "hermes"})`.
6. Apply personality: write the personality prompt to the instance's `SOUL.md` file (at `<data_root>/SOUL.md`), or set `display.personality` in `config.yaml` if the personality is one of hermes's built-in names.
7. Auto-pair the creator: `Instance.add_allowed_id(instance, to_string(creator_user_id))`. Also set `owner_telegram_id` on the instance.
8. Container starts automatically via `BotManager.create` which calls `start/1`.
9. Send confirmation message to the creator with a link to `t.me/<bot_username>`.

### Default bot configuration

New bots provisioned through the manager bot receive:

| Setting | Value |
|---|---|
| `model` | `xiaomi/mimo-v2-pro` (same as Vasya) |
| `bot_runtime` | `hermes` |
| `mention_only` | `true` (require @mention in groups) |
| `allow_all_telegram_users` | `false` (pairing required for strangers) |
| `group_sessions_per_user` | `true` (default hermes behavior) |
| `group_shared_memory` | `false` |
| `language` | user's choice from onboarding |
| Personality | user's choice applied to SOUL.md |
| `daily_token_limit` | `0` (unlimited for now — add limits later) |

### Username generation

```elixir
defp generate_bot_username(display_name) do
  slug = display_name
    |> transliterate()          # "Вася" → "vasya"
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
    |> String.slice(0, 20)      # cap length

  suffix = :crypto.strong_rand_bytes(2) |> Base.encode16(case: :lower)
  "#{slug}_#{suffix}_bot"
end
```

Telegram requires bot usernames to: end in `bot`, be 5-32 chars, contain only `a-z`, `0-9`, `_`. The suffix ensures uniqueness.

If the user edits the username in Telegram's creation UI, the `ManagedBotUpdated.bot.username` field contains the actual chosen username. The instance name is always derived from the actual username, not the suggested one.

### Personality mapping

Hermes built-in personalities (from `cli-config.yaml.example`):

| Key | Label (for keyboard) |
|---|---|
| `helpful` | Помощник |
| `kawaii` | Кавай |
| `pirate` | Пират |
| `noir` | Нуар |
| `philosopher` | Философ |
| `shakespeare` | Шекспир |
| `surfer` | Сёрфер |
| `hype` | Хайп |
| `concise` | Краткий |
| `technical` | Технарь |
| `creative` | Креативный |
| `teacher` | Учитель |
| `catgirl` | Кошкодевочка |
| `uwu` | UwU |

First page of the keyboard shows 8 options (2 rows of 4). "Ещё..." button shows the remaining 6.

Personality is applied by setting `display.personality` in the instance's `config.yaml` via `sync_config`, or by writing hermes's built-in personality prompt to `SOUL.md`. The simpler path: set `display.personality: <key>` in config.yaml — hermes reads this and applies the built-in prompt automatically.

### Config

One new druzhok Setting: `manager_bot_token` — the Telegram Bot API token for the manager bot. Obtainable from BotFather. Stored in the druzhok `settings` table (not the `instances` table — the manager bot is not a hermes instance).

The manager bot's username is derived from the token (via `getMe` API call at startup) and cached.

### Limits

2 bots per user, enforced before generating the creation link:

```elixir
defp user_bot_count(user_id) do
  import Ecto.Query
  Repo.aggregate(
    from(i in Instance, where: i.owner_telegram_id == ^user_id),
    :count
  )
end
```

If at limit, the manager bot responds: "У тебя уже 2 бота — это максимум. Удали один из существующих чтобы создать новый."

### Supervision

```elixir
# In Druzhok.Application children list:
{Druzhok.ManagerBot, []}
```

The GenServer starts on app boot, calls `getMe` to verify the token, then begins long-polling. If the token is not configured (`manager_bot_token` Setting is nil), the GenServer starts but stays idle (no polling).

### Telegram API integration

Long-polling via `getUpdates` with a 30-second timeout. Processes one update at a time (sequential — the manager bot handles low traffic). Uses `Druzhok.Finch` for HTTP.

Key API calls:
- `getMe` — on startup, get the manager bot's username
- `getUpdates(offset, timeout)` — long-poll for updates
- `sendMessage(chat_id, text, reply_markup)` — send messages with inline keyboards
- `getManagedBotToken(user_id)` — fetch a managed bot's token after creation
- `answerCallbackQuery(callback_query_id)` — acknowledge button taps

### Error handling

- Token not configured → GenServer logs warning, stays idle, retries on Settings change
- Telegram API unreachable → retry with exponential backoff (5s, 10s, 30s, 60s cap)
- `getManagedBotToken` fails → log error, send "Ошибка создания, попробуй ещё раз" to user
- `BotManager.create` fails → log error, send error message to user, no partial state left behind
- User sends unexpected input during onboarding → repeat current step's prompt
- Conversation timeout (10 min) → silently expire, next message restarts from `:name`

### Testing

Unit tests:
- Username generation: transliteration, slugification, suffix format, length cap
- State machine transitions: valid and invalid inputs at each step
- Bot limit check: mock Repo to return counts 0, 1, 2
- Provisioning pipeline: mock BotManager.create + Telegram API calls

Integration test (manual):
- Create a test manager bot via BotFather
- Set `manager_bot_token` in druzhok Settings
- Walk through the full onboarding flow
- Verify: instance created in DB, container running, bot responds in Telegram, creator auto-paired

## Open questions

- **Manager bot's BotFather setup**: need to enable "Bot Management Mode" in BotFather's MiniApp for the manager bot before Telegram will send `managed_bot` updates. This is a one-time manual step.
- **Daily token limit for user-created bots**: currently `0` (unlimited). Should add a sensible default (e.g. 500K tokens/day) before opening to non-trusted users.
- **Bot deletion flow**: not in scope, but when added, should the manager bot handle it (user sends "delete @mybot") or only the admin dashboard? Probably both eventually.
