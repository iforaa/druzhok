# Referral invites and the one-bot superbot

Date: 2026-09-19. Gateway side: ruoc-gateway
`docs/superpowers/specs/2026-09-19-referral-invites-for-api-accounts-design.md`.

## Why

Druzhok goes invite-only. A new person can create a bot only with a code: a
referral code a friend got for their own bot, or an invite the operator minted.
Each person gets one bot. Referral codes are the one way, before payments
exist, for a user to earn balance for their bot: the operator sets a referrer
bonus in the ruoc console when they want to, and decides who gets codes by
issuing them from the account's page there. Nothing is issued automatically.

## What ruoc-gateway provides

- `POST /admin/accounts` with `invite`: creates the bot's account and redeems
  the code in one transaction; 409 `invite_invalid | invite_spent |
  invite_expired` otherwise.
- `GET /admin/invites/check?code=` → `available | spent | expired | invalid`.
- `GET /v1/referrals` with the bot's key: the bot owner's codes and their
  status.
- Codes are issued to an account by the operator from the console.

## Admission

Table `admissions`: `telegram_id` (unique), `invite_hint` (first characters of
the code, for the operator's eyes), `admitted_at`. A row means the person may
create a bot, permanently; deleting a bot does not revoke it, so a rename or a
fresh start needs no second code. Written by `BotManager.create` after ruoc
accepted the code, in the same step that saves the instance.

Grandfathering: a data migration admits every `owner_telegram_id` that has an
instance at deploy time. The operator (`Settings.operator_telegram_id`) is
admitted by rule, not by row.

`Druzhok.Admissions`: `admitted?(telegram_id)`, `admit(telegram_id, hint)`.

## The superbot flow

### Entering a code

- Deep link `https://t.me/<superbot>?start=ref_<code>`. `process_update`
  parses `/start <payload>`; a `ref_` payload from a non-admitted user is
  checked through `Ruoc.check_invite/1`. Available: the code is stored in the
  session and the flow continues at "Как назовём бота?". Otherwise the status
  message below, then the normal menu.
- Typed. A non-admitted user pressing «🤖 Создать бота» is told
  "Создание по приглашению. Введи код или открой ссылку от друга." and the
  session moves to step `:invite`; the next text is checked the same way.
  Menu button texts are not treated as codes.

Status messages: spent → "Этот код уже использован."; expired → "Срок этого
кода истёк."; invalid → "Код не найден. Проверь ссылку или попроси новый.";
ruoc down → "Не получилось проверить код, попробуй позже."

An admitted user or the operator never sees the prompt; a `ref_` payload from
them is ignored.

### Creating

The code travels in the session (`session.invite`) to
`Provisioner.provision/4`, into `BotManager.create/2` as `opts[:invite]`, and
to `Ruoc.create_account(label, invite: code)`. A 409 aborts before any local
row: the progress message ends with "Код успели использовать. Попроси новый и
создай бота заново." Success writes the admission and clears the code from
the session. Admitted users send no `invite`.

`@max_bots_per_user` becomes 1. The limit message becomes
"У тебя уже есть бот. Удали его, чтобы создать нового."

### Reply keyboard

Built by `Onboarding.main_menu_keyboard/1` from the user's bot count:

| bots | rows |
|---|---|
| 0 | `[🤖 Создать бота]` |
| 1 | `[🤖 Мой бот] [🎨 Картинки]` / `[🎁 Пригласить] [🗑 Удалить]` |
| 2+ | `[📋 Мои боты]` |

Every place that sends the keyboard (`/start`, after creation, after deletion,
unknown text) computes it fresh. The 2+ case keeps today's list with its
per-bot 💬 🎨 🗑 buttons and exists for the one owner who has two bots; there
is no create for them.

- «🤖 Мой бот»: the bot line from `my_bots_message` (status, balance, plan,
  renewal) with a «💬 Написать» URL button.
- «🎨 Картинки»: `show_image_menu` for the bot, no list in between. «Назад»
  edits the message into the «Мой бот» card.
- «🗑 Удалить»: the existing confirm flow. After deletion the keyboard is
  rebuilt with `[🤖 Создать бота]`.
- «🎁 Пригласить»: `Ruoc.referrals(api_key)`.
  - available codes: "Пригласи друга — по этой ссылке он сможет создать
    своего бота:" then one message per available code with the link and an
    inline «Поделиться» button
    (`https://t.me/share/url?url=<link>&text=<caption>`). When the referrer
    bonus on the code is above zero the caption says what they get.
  - redeemed codes: "Использован <5 окт>" lines under the list.
  - no codes: "У тебя пока нет приглашений."
  - ruoc error: "Не получилось загрузить приглашения, попробуй позже."

### Ruoc client

- `create_account(label, opts)`: `opts[:invite]` → body `invite`; 409 →
  `{:error, {:invite, :invalid | :spent | :expired}}`.
- `check_invite(code)` → `{:ok, :available | :spent | :expired | :invalid} |
  {:error, reason}`.
- `referrals(api_key)` → `{:ok, [%{code, status, redeemed_at, friend_nanorub,
  you_nanorub}]} | {:error, reason}`.

## Tests

- `Onboarding`: keyboard per bot count; `:invite` step accepts a code and
  rejects menu texts; messages for each status.
- `ManagerBot` update handling: `/start ref_x` for admitted vs not; typed code
  path; «🎁 Пригласить» rendering with a stubbed `Ruoc`.
- `Provisioner` / `BotManager.create`: invite passthrough, 409 leaves no row,
  success writes the admission, admitted user sends no invite.
- migration: grandfathering admits existing owners.
- `Ruoc` client against a Bypass server: `invite` body, 409 mapping, check
  statuses, referrals decoding.

## Rollout

Gateway first (its spec's rollout). Then druzhok: rsync, migrate (admissions
+ grandfathering), restart. Verify with a code issued to the operator's bot:
open the link from a second Telegram account, create a bot, see the code turn
"использован" under «🎁 Пригласить».
