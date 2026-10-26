# Panel controls: owners change settings and delete the bot in the Mini App; the superbot only creates

Status: implemented on branch `panel-controls` (2026-10-26); draft r4 (reviewed by revmux `chat-surface-panel-specs/01-initial`, `02-after-fix`, `03-final`). Follows
`2026-10-24-bot-panel-design.md` (the read-only panel). Second opinions from gpt-6-astra and gpt-6.1-sol
(2026-10-26) agreed on the shape: the panel is the owner's control centre, the superbot is the way in.

## Why

- The panel shows every setting (Ещё tab, `src/more.tsx:15-28`) and then says «Изменить настройки пока можно
  через поддержку.» (`more.tsx:82-86`). The API is GET only (`router.ex:63-71`).
- The only owner controls are in the superbot: 🎨 Картинки (model picker, off) and 🗑 Удалить
  (`manager_bot.ex:252-267`, callbacks `img:`/`imgset:`/`imgoff:`/`del:`/`delyes:`/`delno`). Everything
  else (language, timezone, group mode, site) is operator-only through `ops/druzhok set`.
- Two places for one bot confuse owners. The owner wants the superbot for creating a bot only.

## Goals

1. An owner can change, from the panel: answer language, timezone, group mode, pictures (on/off and the
   model), site publishing.
2. An owner can start deleting the bot from the panel; the deletion is confirmed in the superbot, a channel the
   tenant bot cannot control.
3. A change never wakes a sleeping bot and never cuts off an answer in progress. A change waits as long as it
   must; it is not forced.
4. The owner sees whether a change is saved, waiting, applied, or failed.
5. The superbot keeps: create a bot, redeem an invite, invite a friend, a pointer to the bot's «Кабинет», and
   the final confirmation of a delete started in the panel.
   Картинки and Удалить leave it for every owner who has a working panel.
6. Nothing the operator owns becomes writable from the panel (token, owner, chat model, vision model, memory
   engine, sleep, allowed chats).

## Design

### Writable fields

One allowlist in a new `Druzhok.Panel.Settings` module. The POST body uses **the same names as `GET
/app/api/bot`** (`panel.ex:74-89`), which are the `Instance` field names; the module validates each value and
passes nothing else to `BotSettings`.

| Field | Values | Applies |
|---|---|---|
| `language` | `ru`, `en` (the create flow's set, `onboarding.ex:103-104`) | restart |
| `timezone` | an IANA name that `Tz` (`config.exs:25`) knows, e.g. `Asia/Almaty`; `UTC` | restart |
| `mention_only` | boolean: true «отвечает, когда зовут», false «отвечает на всё» | restart |
| `image_gen_enabled` | boolean | restart |
| `image_gen_model` | an `id` from `Ruoc.image_models/0`, or `null` for ruoc's default | live |
| `website_hosting_enabled` | boolean | restart |

Not writable: `model`, `sleep_enabled`, `memory_provider`, `group_shared_memory`, `trigger_name` (shown
read-only as today), and `image_model`, the operator's **vision** model (`instance.ex:21`, a different field
from `image_gen_model`), which the panel does not show and does not start showing. The allowlist is the six names above; a test sends every other
`BotSettings.fields/0` name and expects `400 unknown_setting`.

The UI for timezone is a short list (Asia/Almaty, Europe/Moscow, Asia/Tashkent, Europe/Istanbul, Asia/Tbilisi,
UTC) plus «Другой…», which accepts any IANA name, validated server-side.

`image_gen_model` is accepted only while `image_gen_enabled` is true after this request's own changes;
otherwise `400 images_off`. The catalogue comes from `Ruoc.image_models/0` (not cached); the panel gets it
from a new `GET /app/api/image-models`, a thin pass-through that answers 502 `catalogue_unavailable` on error,
like `invites`.

### API

- `POST /app/api/settings`, body `{"changes": {"language": "en", "image_gen_enabled": true, ...}}`.
  - Behind the same `:panel_api` pipeline (`PanelAuth`: edge header, Telegram signature + token HMAC, owner,
    not `cabinet_off`).
  - All fields validated first; one bad field refuses the whole request. No partial writes. Unchanged values
    are dropped before the write.
  - Errors use the panel's envelope `{"error": {"type", "message"}}` with a short English `message`
    (`PanelAuth.error/4`); the owner's Russian wording stays in one place, `explain()` in `api.ts`, which gains
    the new types: `unknown_setting`, `invalid_setting`, `images_off`, `catalogue_unavailable`. The panel
    knows which row it saved, so no `field` key is needed.
  - Answers `{"bot": <the GET /bot shape>}`; the new `apply` object in it (below) says what happens next.
- `POST /app/api/delete`. See «Delete».
- `api.ts` gets a POST twin of `panel<T>()` (today GET only, `api.ts:83-85`).
- The existing 60/min rate limit covers it. Writes for one bot are serialized with `:global.trans` keyed by
  the bot id, as `BotManager.create` does for names.

### Applying a change

Today `BotSettings.update/2` restarts at once when the bot is `active` and a restart field changed
(`bot_settings.ex:63-67`), and `BotManager.restart` wakes a sleeping bot (`bot_manager.ex:128-142`). The
panel needs neither.

**Two new row fields, in the lifecycle's own seq style:** `settings_seq` (bumped by every panel save that
changes a restart field) and `settings_applied_seq` (the `settings_seq` a successful start ran with), plus
`settings_saved_at` (time of the last such save).

- `BotSettings.update(name, attrs, restart: :when_quiet)` writes the fields and, if a restart field changed,
  bumps `settings_seq` and sets `settings_saved_at`, all in one update. It never calls `BotManager.restart`.
  `ops/druzhok set` keeps today's immediate restart.
- **Any start applies pending settings.** `Lifecycle.Bot.start_action/2` already re-reads the row before it
  starts (`lifecycle/bot.ex:220`); it keeps that row's `settings_seq` and, when the start succeeds
  (`started/4`, where `applied_seq` is set, `bot.ex:269`), writes `settings_applied_seq` = that value. A save
  that lands after the re-read has a higher `settings_seq` and stays pending. So a wake, an `ops/druzhok
  restart`, crash recovery or a stop+start each apply what was saved before them, and no extra restart
  follows.
- **A quiet restart for an awake bot.** In `awake/2` (`bot.ex:164`), when `settings_seq >
  settings_applied_seq`, the controller looks for a quiet moment on its tick:
  1. `Idle.check(inst, window_s: 60, only: [:telegram, :proxy, :turns, :processes])`: no Telegram update and
     no proxy call in the last 60 s, no running turn, and no process in the unit's cgroup besides hermes
     (a terminal or background job the agent started; a stop would kill it). `only:` is a new option
     selecting existing checks (`no_telegram`, `no_proxy_calls`, `no_turns`, `one_process`, `idle.ex:44-47`).
     `wanted`, `not_paused`, `started_long_ago` and `no_cron` are not part of it: they decide sleep, not this.
  2. If quiet: hold the relay (`hold(id, :stopping)`) and `Relay.quiesce`, re-read the row and run **the
     same** `only:` check again, the way `sleep_action` re-checks after its own hold (`bot.ex:337-343`).
     `own_pause` is not used: the pause check is not in the list, so the controller's own `stopping` hold does
     not count as busy. An update that slipped in before the hold is caught here.
  3. Still quiet: run `start_action` (it stops the unit through `stop_unit` and starts it). Not quiet:
     `Webhook.resume_if(id, :stopping)` and wait for the next tick.
  There is no deadline. A bot that is never quiet keeps the change pending until it is. While a change
  is pending an awake bot does not fall asleep: an idle bot is quiet, so it is restarted instead. Only a bot
  already asleep when the change was saved applies it on its next wake. The panel says so.
- **Asleep or stopped bots** are left alone: `sync_config` and `env_vars/1` run on every start and wake
  (`BotManager.prepare_start/1`), so the next one applies the change.

**What the panel shows** — `GET /app/api/bot` gains
`"apply": {"state": ..., "error": ...}`:

| state | when | text |
|---|---|---|
| `applied` | `settings_seq == settings_applied_seq` | «Сохранено» (also right after a live-only change) |
| `waiting` | pending, bot awake | «Применится, когда бот закончит отвечать» |
| `on_wake` | pending, `sleeping` | «Применится, когда бот проснётся» |
| `on_start` | pending, not `active` | «Применится при следующем запуске» |
| `failed` | pending and `start_failed_at > settings_saved_at` | «Не получилось применить. Напишите в поддержку» (+ support link when `support_url` is set) |

The `failed` test compares timestamps so an old `start_error` from before the save is not shown. The panel
polls `GET /bot` every 3 s while the state is `waiting`, up to 2 min, then stops polling and keeps the last
text.

### Panel UI (Ещё tab)

- Each writable row opens a small sub-screen (the pattern of `more.tsx:30-34`, BackButton) with the choices as
  tappable rows and a check mark on the current one. A choice saves at once; there is no Save button.
- New `Choice` and `Toggle` rows in `ui.tsx` (only `Row` exists today). `Toggle` for pictures and site,
  `Choice` lists for language, timezone, groups, picture model (with its `rub_per_image`, «по умолчанию» on
  the default).
- The bot's `apply` text shows under the settings list; validation errors show inline on the row.
- The note «Изменить настройки пока можно через поддержку.» goes.
- Site: turning it on asks first, in a `showConfirm`: «Сайты, которые сделает бот, будут открыты всем по
  ссылке <name>.oldey.dev». `telegram.ts`'s `WebApp` type gains `showConfirm` and `showPopup`.

### Delete

- «Удалить бота» at the bottom of Ещё, red, apart from the settings.
- Step 1: a sub-screen that says what is lost: the bot stops answering; its memory, files, reminders and site
  are deleted; this cannot be undone; the paid plan is not refunded. Button «Удалить бота».
- Step 2: the panel sends the request; the final «Удалить» is in the superbot (below).
- **The panel alone cannot authorize a delete.** Init data is bound to this bot, but the bot itself can
  phish it: a prompt-injected bot can send its owner a `web_app` button to a page it controls and capture
  fresh init data from the owner's webview (bot panel spec, `2026-10-24-bot-panel-design.md:128-133`, which
  left writes needing "an extra step", `:466-469`). A freshness window does not help, since phished data is
  fresh. So the confirmation goes through a channel the tenant bot cannot control: **the superbot**.
- `POST /app/api/delete` (normal `PanelAuth`) only creates a request: the row gets `delete_confirm_token`
  (random, 128 bit) and `delete_confirm_expires_at` (now + 10 min). It answers `202 {"confirm_in":
  "@<superbot>"}`; a second request while one is live reuses it.
- The superbot sends the owner (`owner_telegram_id`, its private chat) «Удалить бота @handle навсегда? Память,
  файлы, напоминания и сайт будут удалены. Это нельзя отменить.» with `✅ Удалить` (`pdel:<token>`) and
  `❌ Отмена` (`pdelno:<token>`). The superbot already knows the owner's chat: they created the bot there.
- On `pdel:<token>`: the superbot checks the token, its expiry, and that the tapping user is the row's owner
  (`owned_instance`, `manager_bot.ex:661-668`), then clears the token and calls `BotManager.delete(name)`
  without waiting: one row update (`active` false, `delete_requested` true) and `Lifecycle.poke`; the
  controller stops, destroys, wipes and suspends, retrying on failure as today (`lifecycle/bot.ex:81-103`).
  This is the owner's explicit request, the case CLAUDE.md allows for wiping the data dir. It edits the message
  to «✅ Бот @handle удаляется» and sends the 0-bot main menu. `pdelno` or expiry clears the token.
- If the superbot cannot reach the owner (`403 Forbidden: bot can't initiate conversation`: an owner who never
  started the superbot, e.g. a bot the operator created), the panel request answers `409
  superbot_unreachable` and the panel says to open @<superbot> first, with a t.me link, and try again.
- The panel shows «Подтвердите удаление в @<superbot>» with a t.me link, and polls `GET /bot`; once it 404s
  (`find_bot` excludes `delete_requested`) it shows «Бот удалён» and closes on tap.
- Settings writes are not gated this way: they are reversible, the owner sees them in the panel, and the one
  with outside effect, publishing the site, serves only files the bot itself writes, which a compromised bot
  controls anyway. The site toggle still asks the owner first (`showConfirm`, above).

### Superbot

An owner keeps the superbot's controls when the panel cannot serve them. `Onboarding.panel_ready?(bot)` is
true only when the bot is not `cabinet_off` (`PanelAuth` answers 403, `panel_auth.ex:97-100`), a public host is
set, `cabinet_menu_set` is true and `cabinet_url` is the panel's URL (`Panel.url/2`): the owner's «Кабинет»
button exists and opens druzhok's panel. A bot whose binding or button never succeeded (no ruoc account, the
binding keeps failing, a first start that failed before `Cabinet.sync`) is not panel-ready. Everything below
applies only to panel-ready bots; the others keep today's superbot exactly.

- Keyboard with one bot becomes `[🤖 Мой бот], [🎁 Пригласить]` (today `[🤖 Мой бот, 🎨 Картинки],
  [🎁 Пригласить, 🗑 Удалить]`, `onboarding.ex:41-50`). With two or more bots (operator only) `📋 Мои боты`
  stays, and rows of panel-ready bots keep 💬 only.
- The «Мой бот» card adds: «Настройки, тариф и удаление — в «Кабинете»: откройте бота и нажмите «Кабинет»
  внизу.» A `web_app` button from the superbot cannot open the panel: its init data would be signed for the
  superbot's id and fail `PanelAuth`. The «💬 Написать» t.me button stays.
- Old messages still carry `img:`, `imgset:`, `imgoff:`, `del:`, `delyes:`, `delno`, `imgback` buttons. For a
  panel-ready bot they answer with an alert, «Теперь это в «Кабинете» бота», and do nothing; for the others
  they work as today.
- The old labels «🎨 Картинки» and «🗑 Удалить» stay in `Onboarding.menu_texts/0` (non-panel-ready owners
  use them). `one_bot_menu/4` gets a panel-ready branch for both: it answers «Теперь это в «Кабинете» бота:
  откройте бота и нажмите «Кабинет» внизу.» together with the new main-menu keyboard, which replaces the
  persistent old one.
- `after_create_message` («Управление ботом — в меню внизу.») becomes «Настройки — в «Кабинете» бота: кнопка
  внизу в чате с ботом.»
- Operator: unchanged; `ops/druzhok` is the operator's control surface.

## Not in scope

- Chat-model picker (needs a curated list with prices; later spec).
- Memory: viewing is in the panel; correcting and forgetting facts is a later spec.
- Sleep, memory engine, trigger name, allowed chats, vision model: operator-only.
- A panel entry point from the superbot (needs a separate auth path).

## Tests

- `Panel.Settings`: each field's accepted and refused values; every other `BotSettings.fields/0` name refused
  (including `image_model`, `model`, `telegram_token`, `owner_telegram_id`); `image_gen_model` with pictures
  off; unchanged values dropped.
- `BotSettings.update/3` `restart: :when_quiet`: no restart and no wake in every state; `settings_seq` bumped
  only for restart fields; live-only change leaves it.
- `Lifecycle.Bot`:
  - any successful start sets `settings_applied_seq` to the seq read in `start_action`; a save after that
    read stays pending;
  - quiet restart: waits while busy; a busy recheck after the pause resumes the relay and does not restart;
    restarts when quiet twice; never forced;
  - a sleep while pending: no restart; the wake applies it and nothing restarts again;
  - a failed start after a save → `apply.state` `failed`; an older `start_error` does not count.
- `panel_api_test.exs`: POST settings auth (no edge, bad signature, not owner, `cabinet_off`), 400 envelope,
  success shape with `apply`; POST delete creates a token and does **not** mark `delete_requested`, reuses a
  live token, answers 409 when the superbot cannot message the owner; `GET /image-models` pass-through and 502.
- `manager_bot_test.exs` (panel delete): `pdel:` with a valid token from the owner deletes; a wrong token, an
  expired token, a different user, or a second tap does nothing; `pdelno` clears the token.
- `manager_bot_test.exs` / `onboarding_test.exs`: one-bot keyboard and card for a panel-ready bot; the old
  keyboard and working callbacks for a `cabinet_off` bot; old callbacks on a panel-ready bot answer the alert
  and change nothing (picture fields and `delete_requested` untouched).
- Frontend: `npm run build` passes; manual pass in Telegram on the operator's bot for every row, delete on a
  throwaway bot.

## Rollout

1. Ship druzhok (migration adds `settings_seq`, `settings_applied_seq`, `settings_saved_at`,
   `delete_confirm_token`, `delete_confirm_expires_at`), with
   `ops/build-app.sh` output committed.
2. Operator's bot: change each setting from the panel, watch `apply`, confirm the config/env change
   (`config.yaml`, `TZ`); change a setting while the bot answers a long request and check it waits; change one
   while it sleeps and check it stays asleep.
3. Delete a throwaway bot created for the test.
4. Superbot keyboards change when a user next gets the main menu (`/start`, any stale text, or tapping an old
   🎨/🗑 label). Inline-keyboard replies such as the «Мой бот» card do not resend it; until then the old
   buttons are handled as above.

Rollback: revert the commit; the new columns are additive. Saved settings are already in their fields, so the
next start or wake applies them under the old code too; nothing is left pending in a way the old controller
would trip on.
