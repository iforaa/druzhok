# Tenant chat surface: commands and hermes's fixed replies in druzhok's words

Status: draft r4, 2026-10-26 (reviewed by revmux `chat-surface-panel-specs/01-initial`, `02-after-fix`, `03-final`). Batch 3 of the
hermes review (batch 1 `2026-10-25-hermes-config-tuning-design.md`, batch 2 `2026-10-25-bot-voice-design.md`;
batch 2 changed what the *model* says, this changes what hermes itself prints). Second opinions from
gpt-6-astra and gpt-6.1-sol (2026-10-26).

All hermes paths are in the fork `hermes-agent/` (0.22.2, HEAD f1ef996); ru.yaml means `locales/ru.yaml`.

## Why

Tenants are non-technical Russian speakers. Replies that hermes builds itself (no model involved) still talk
like a developer tool:

- **Menu** (`hermes.ex:573`, `@menu_commands ~w(new compress status voice)`): «Сжать контекст разговора
  (добавьте 'here [N]'…)», «Показать сведения о сеансе, модели, токенах и контексте».
- **`/new`** first asks for confirmation: `_hm_cmd_new` runs `_maybe_confirm_destructive`
  (`run_inbound.py:862-870`) because `approvals.destructive_slash_confirm` defaults to true
  (`hermes_cli/config_defaults.py:1700`) and druzhok never sets it. The prompt (`gateway.confirm.*`, ru:764-766)
  offers «Одобрять всегда» (which persists into config.yaml) and a `/approve` fallback that tenants may not run.
  After confirming: a header, then a session-info block (`run_turn.py:2337-2372`: model, provider «custom»,
  context tokens, and «Конечная точка: http://127.0.0.1:4000/v1» because the proxy is on localhost), then a
  random CLI tip (`hermes_cli.tips`, e.g. «hermes -c»). The auto-reset notice appends the same block
  (`run_turn.py:563-568`).
- **`/status`** (ru:425-440): «Состояние Hermes Gateway», session id, model and provider, lifetime tokens. On
  the busy path `/status` and `/context` run before the access gate, deliberately («intentionally pre-gate so
  users always see session state», `run_inbound.py:601-605`), so a tenant gets them even when not allowed.
- **`/start`** is a hermes built-in that answers nothing (`run_inbound.py:872`, `run_busy.py:1009`; an empty
  reply is not sent, `platforms/base.py:4590`). Built-ins win over quick commands (`run_inbound.py:826-835`),
  so druzhok's `quick_commands.start → new` alias (`hermes.ex:1005-1012`, and the seed in
  `build_config_yaml/1`, `hermes.ex:1174-1177`) never runs. A new user tapping «Start» gets silence.
- **`/help`**: «📖 Команды Hermes» (ru:206); `/start` is listed as «Принимать стартовые пинги платформы без
  ответа» (ru:1492).
- **Denied command**: «⛔ /model здесь доступна только администраторам. Вам доступны: …» (ru:639-642;
  `admin_only_none` names `allow_admin_from`). `/whoami` shows platform, raw user id and admin/user tiers
  (ru:851-857). The hermes "admin" is the operator (`allow_admin_from` = `operator_telegram_id`,
  `hermes.ex:581-587`); the bot's owner is a hermes "user".
- **`/voice`**: «Авто-TTS включён» (ru:563, labels ru:572-574).
- **Failures** that reach a tenant: compression (`hermes doctor`, `auxiliary.compression.model в config.yaml`,
  raw `{error}`, `/compress`, ru:143-154), provider errors (`/login`, `/model`, `/retry`, `hermes doctor`,
  `hermes logs`, ru:659-687), turn timeout (`agent.gateway_timeout в config.yaml`, ru:817), exception class
  names (`notify.turn_error_detailed`, ru:633), the no-reply explainers (`explainer.*`, ru:3444+: «смените
  модель через /model», «другой процесс Hermes»), approvals («Hermes хочет выполнить команду», ru:603, 608).
- **Outside the obvious places**: an unknown `/foo` skips the access gate (it applies to known commands only,
  `run_inbound.py:837-844`) and gets `gateway.unknown_command` («…Введите /commands…», ru:794, a command
  tenants cannot run); a skill name typed as a command gets `gateway.skills.*` with `hermes skills install`;
  a finished background process sends `gateway.background.*` («✅ Фоновая задача завершена — `<shell
  command>`», with exit code and output tail on failure; `display.background_process_notifications` defaults
  to `concise`). The first follow-up sent while the bot is busy gets an English hint recommending `/busy
  queue|steer|status` (`agent/onboarding.py:31-51`, `run_busy.py` `_compose_busy_ack_message`), hardcoded,
  shown once per bot until `onboarding.seen.busy_input_prompt` is set.
- **Stranger DMs get nothing**: druzhok always sets `TELEGRAM_ALLOWED_USERS` (`hermes.ex:79`) and no
  `unauthorized_dm_behavior`, so hermes uses `ignore` (`gateway/authz_mixin.py:702-746`) and the Telegram
  adapter drops the message (`plugins/platforms/telegram/adapter.py:942-993`). The pairing texts are
  unreachable; this spec does not change that.
- The gateway's empty-reply text is **not** from the catalog: `run_turn.py:1541-1546` formats the English
  constant `EMPTY_RESPONSE_EXPLANATION` (`agent/turn_explainers.py:22`, model name + `/model`) into
  `gateway.shared.warn_passthrough`, so no overlay reaches it.
- **Broadcasts**: shutdown/startup notices (ru:838-845) are already off for druzhok
  (`gateway_restart_notification: false`); `progress.task_card_title` «Hermes работает» (ru:828).

## Goals

1. The menu has only what a person uses in a chat: new conversation, stop, voice replies, help.
2. `/start` greets instead of staying silent, and never resets a conversation. `/new` resets without a
   confirmation prompt.
3. No tenant-visible fixed reply names Hermes, a model, a provider, a URL, a config key, a CLI command, an
   exception class, or a command the tenant cannot run. Failures say what happened in plain words and what to
   do (wait, write again, /new, «Кабинет»).
4. As much as possible without a fork change; the fork change is small, behind one config flag, and
   upstreamable.

## Design

### 1. Commands (druzhok config only)

`hermes.ex`:

- `@user_commands ~w(start new stop voice)` (was `start new compress status voice`). `/help` and `/whoami`
  stay allowed by hermes's floor (`gateway/slash_access.py:19`). `/compress` and `/status` become denied.
  Automatic compaction (150K trigger, batch 1) covers what `/compress` did.
- `@menu_commands ~w(new stop voice help)`, `priority_mode: replace`, `max_commands: 4` (the existing
  mechanism, `commands_platforms.py:118-143`).
- `/stop` on the gateway interrupts the current answer and keeps the conversation
  (`slash_commands.py:420-482`, replies ru:447-449, already clean). Its menu description is the CLI one
  («Завершить все запущенные фоновые процессы», ru:1530); the overlay below replaces it.
- `approvals.destructive_slash_confirm: false`, written by `sync_config` (an owned key in the `approvals`
  block, upserted like the other owned keys). `/new` then resets at once; the overlay still covers
  `gateway.confirm.*` in case another destructive command is ever allowed.
- `onboarding.seen.busy_input_prompt: true`, written by `sync_config` (owned key), so hermes never shows its
  hardcoded English busy-input hint (`agent/onboarding.py:23-51`, flag `BUSY_INPUT_FLAG`). No fork change.
- The `quick_commands.start → new` alias goes from both places: `build_config_yaml/1` no longer seeds it, and
  `sync_quick_commands/1` becomes a step that removes a `quick_commands:` block whose only entry is druzhok's
  `start: {type: alias, target: new}`; any other `quick_commands` content is left alone. The removal step can
  be dropped once every live bot has started once on the new code.

### 2. Locale overlay (druzhok, no fork change)

Hermes merges a per-home overlay over its bundled catalog: `<HERMES_HOME>/locales/<lang>.yaml`, flattened
key by key, cached once per process and home (`agent/i18n_layers.py:205-230`; precedence plugin packs >
overlay > bundled, `agent/i18n.py:148-161`). `HERMES_HOME` is the tenant dir (`hermes.ex:71`). So druzhok can
replace any static text, per bot, with no fork change. A broken overlay file is logged and ignored
(`i18n_layers.py:220-226`): every override then silently reverts to hermes's text, so the file must always
parse.

- New `Druzhok.Runtime.Hermes.Locale`. On every start and wake, `sync_config` writes
  `<home>/locales/ru.yaml` and `<home>/locales/en.yaml` through `TenantFiles` (create, owner check, no
  symlinks), the same way batch 2 writes SOUL.md. The files are druzhok-owned and rewritten whole each time;
  the first line is a marker comment (`# druzhok-owned: rewritten on every start`). If the content is
  unchanged nothing is written.
- Source: `apps/druzhok/priv/hermes_locale/ru.json` and `en.json`, the overrides only, flat
  `{"dotted.key": "text"}` (druzhok has no YAML library at runtime). Druzhok substitutes the bot's name and
  **emits** the file itself, one `"dotted.key": "text"` line per override: key and value are JSON-encoded
  strings (`Jason.encode!`), which are valid YAML double-quoted scalars (the technique batch 2 uses for
  `agent.system_prompt`), and hermes's `flatten` keeps a dotted key as it is. No raw text is spliced into YAML.
- **The bot's name** (`display_name`, the Telegram first name, set by the owner) is the only substitution.
  Source values say `%{bot_name}`; druzhok replaces it with the name with `{` and `}` replaced by `(` and
  `)`. Doubling them would not work: `t()` runs `str.format` only when the caller passes kwargs
  (`agent/i18n.py:236-237`), so `{{` would show literally in keys formatted without them, and a single brace
  breaks the ones formatted with them. Empty name → «Дружок» (as `Voice.sync_soul`).
- **Placeholders.** Hermes formats with `str.format(**kwargs)`; unused keyword arguments are ignored, so an
  override may drop placeholders (`{model}`, `{error}`, `{approve_cmd}`). A placeholder hermes does not pass
  does not raise: `t()` catches the formatting error and returns the unformatted text
  (`agent/i18n.py:239-243`), so the user would see a literal `{x}`. The test below therefore requires each
  override's placeholders to be a subset of the bundled key's.

**Scope: every key accounted for.** The overlay audit covers **all** of `gateway.*` (91 sub-namespaces in
hermes 0.22.2 ru.yaml), `explainer.*`, `approval.*`, `platform.telegram.*` (the Telegram adapter's own
replies, e.g. `media.download_failed` with the exception class name, `adapter.py:6303-6320`, and
`prompt.expired_toast`/`expired_body` with `/retry`, `adapter.py:4599-4605`), and
`slash.{new,stop,voice,help,start,whoami}.description`.
Each key is either **overridden** in `priv/hermes_locale/ru.yaml` or covered by a line in
`priv/hermes_locale/reviewed.txt`. A reviewed line names a key or a whole sub-namespace and gives a reason:

- `clean` — the text is fine as hermes has it (e.g. `gateway.stop.*`);
- `unreachable: <why>` — tenants cannot trigger it, e.g. `gateway.model.*` «/model is admin-only»,
  `gateway.topic.*` «/topic denied», `gateway.pairing.*` and `gateway.unauthorized.action_notice`
  «strangers are ignored (allowlist, ignore mode)», `gateway.unauthorized.owner_notice`/`owner_hint_*`
  «operator home channel», `gateway.shutdown.*`/`startup.*` «notices off».

The audit test fails on a key that is neither, so a hermes update that adds or moves a key anywhere under
these roots fails until someone looks at it. Namespaces matter most where tenants do reach them:

| Namespace | Reaches a tenant via |
|---|---|
| `gateway.reset.*`, `gateway.session.*` | /new, auto-reset after a suspension |
| `gateway.help.*`, `gateway.whoami.*`, `gateway.unauthorized.admin_only*` | /help, /whoami, denied commands |
| `gateway.unknown_command`, `gateway.skills.*` | any unknown `/foo`, a skill name typed as a command |
| `gateway.voice.*`, `gateway.busy.*` | /voice, messages sent while the bot is busy |
| `gateway.background.*` | background process finished/failed |
| `gateway.compress.*` | automatic compaction failures |
| `gateway.errors.*`, `gateway.notify.*`, `gateway.shared.*` | provider and turn failures |
| `gateway.progress.*` | timeouts, task card |
| `gateway.exec_approval.*`, `gateway.confirm.*`, `approval.*` | approval and confirmation prompts |
| `explainer.*` | no-reply and persistence explainers |

What the overrides say (ru; en is the same in English):

| Keys | New text (gist) |
|---|---|
| `slash.new/stop/voice/help.description` | «Новый разговор», «Остановить ответ», «Голосовые ответы», «Что я умею» |
| `slash.start.description`, `slash.whoami.description` | «Начать», «Мой доступ» (they show in `/help`) |
| `gateway.help.header` | «📖 Команды» |
| `gateway.reset.header_*` | «✨ Начинаем новый разговор. Что я о вас помню — осталось.» (titled variant keeps `{title}`) |
| `gateway.reset.tip` | empty (drops the CLI tip line) |
| `gateway.session.auto_reset_notice` | sent only after a suspension (`run_turn.py:561`; crash/stuck-loop guard, `run_shutdown.py:1326-1345`): «Прошлый разговор пришлось закрыть из-за сбоя. Начинаем новый — что я о вас помню, осталось.» (no `/resume`) |
| `gateway.unauthorized.admin_only*`, `gateway.unknown_command` | «Эта команда недоступна. /help — что я умею.» / «Такой команды нет. /help — что я умею.» |
| `gateway.skills.*` (tenant-reachable keys) | «Такой команды нет. /help — что я умею.» (no `hermes skills …`) |
| `gateway.whoami.header`, `tier_*` | no platform, scope or user id; tiers worded neutrally: admin/unrestricted «Доступны все команды», user «Доступные команды: {commands}». No «владелец»: the hermes admin is the operator, the owner is a hermes user |
| `gateway.voice.*` | «Буду отвечать голосом» / «Отвечаю текстом» / …; no «TTS» |
| `gateway.busy.*` (tenant-reachable) | no «Hermes», no `/busy`, `/queue`, `/steer` |
| `gateway.background.*` | «✅ Готово» / «Не получилось выполнить задачу». The shell command is appended in code, not through a placeholder (`gateway/run.py:2989-2996`), so fork item 5 removes it |
| `platform.telegram.media.download_failed`, `prompt.expired_*` | «Не получилось загрузить файл. Пришлите его ещё раз.» (no `{error}`) / «Эта кнопка устарела. Напишите ещё раз.» (no /retry). Admin-only or disabled keys (`picker.*`, `prompt.update_*`, `install_hint`, `slash_confirm.*`) go in `reviewed.txt` as unreachable |
| `gateway.compress.*` | «Разговор стал слишком длинным, и сжать его не получилось. Начните новый: /new.» (no `{model}`, `{error}`, config keys, /compress) |
| `gateway.errors.*`, `notify.*`, `shared.*` | plain text per case: rate limit / overload «Сервис сейчас перегружен, попробуйте через минуту»; generic «Не получилось ответить. Напишите ещё раз»; context overflow «Разговор стал слишком длинным. Начните новый: /new»; 402 «Лимит тарифа на сейчас исчерпан — подробности в «Кабинете»» (matches `BalanceNotice`); no /retry, /model, /login, /compress, class names |
| `explainer.*` | «Не получилось ответить в этот раз. Напишите ещё раз.» family; persistence cases «Не получилось сохранить разговор, я остановился. Напишите ещё раз через минуту»; no model, /model, /retry, Hermes, paths (`{home}` dropped) |
| `gateway.progress.timeout_*` | «Ответ занял слишком долго, я остановился. Напишите ещё раз.» (no tool name, no config key) |
| `gateway.progress.task_card_title` | «%{bot_name} работает» |
| `gateway.exec_approval.header`, `timed_out_notice`, `gateway.approval_expired` | «%{bot_name} хочет выполнить действие…» (no config keys, no `/approve`). `gateway.confirm.*` is reviewed as unreachable (the confirmation is off); `approval.*` is the CLI prompt or clean |

### 3. Fork change: `display.end_user_mode`

What the overlay cannot do, because the text is assembled in code. One boolean, default false, read like
other display keys (`cfg_get(_load_gateway_config(), "display", "end_user_mode")`, default added in
`hermes_cli/config_defaults.py:818`; per-profile scope as `run_turn.py:2342` does). Druzhok writes
`display.end_user_mode: true` in `sync_display_block`. With it on:

1. **Reset notices without session info.** `/new`, `/reset` (`slash_commands_session.py:189`) and the
   auto-reset notice (`run_turn.py:565`) omit `_format_session_info` and the tip.
2. **`/start` greets.** `_hm_cmd_start` (`run_inbound.py:872`) and `_busy_start_command` (`run_busy.py:1009`)
   reply `t("gateway.start.greeting")` instead of `""`, and never reset or forward to the model. New key in all
   17 catalogs (the parity test, `tests/agent/test_i18n.py`); en «👋 Hi! Write me anything — text or a voice
   message. /help — what I can do.». Druzhok's overlay gives the persona text with the bot's name. With
   `/start <payload>` (deep links) the payload is ignored.
3. **Access gate before `/status` and `/context` on the busy path** (`run_inbound.py:601-605`): with the flag
   on, run `_check_slash_access` first, as the idle path does (`:843`). With the flag off the current
   deliberate behaviour (and its comment) stays.
4. **Localized empty reply.** The gateway's `(empty)` rewrite (`run_turn.py:1541-1546`) uses
   `empty_response_explanation(model)` (`agent/turn_explainers.py`, catalog key `explainer.empty_response`)
   instead of the English constant, so the overlay applies. (Arguably right with the flag off too; kept under
   the flag to stay a no-op for upstream by default.)

5. **No shell command in background-task notices.** `_format_concise_process_notification`
   (`gateway/run.py:2989-2996`) skips the appended command (`— <command>`), the exit code and the failure
   output tail; the status line
   (overlaid) stays, so the tenant still learns a job finished or failed.

Not in the flag: the `/help` skill section is already hidden for gated users (`allowed` is non-empty,
`slash_exec.py:108-124`); the hardcoded English context source (`run_turn.py:2352`) is inside the hidden
session info.

The change is one fork commit, with a customization entry in the `update-hermes` skill (customization 8:
intent, the five sites, idempotency check `grep -c end_user_mode gateway/slash_commands_session.py`, verify
commands). The flag is generic ("hosted for end users"), so it can be offered upstream.

### 4. `update-hermes` skill checks

Add to the skill's Step 0:
- the druzhok overlay audit test (below) against the new tag's catalog: every overridden key still exists,
  placeholders are a subset, and every key under the audited roots is overridden or reviewed;
- `approvals.destructive_slash_confirm`, `command_menu` and the slash-access keys are still read;
- `stop` is still a gateway command; `/start` is still a built-in.

## Not in scope

- Rewriting replies in the proxy: these are generated inside hermes and never pass through it.
- Owner-facing and operator-only texts.
- Stranger DMs: they stay ignored (allowlist); owners adding people is a later feature.
- A chat-model picker, memory editing.
- Passing `agent.system_prompt` to cron runs (separate fork item).

## Tests

- **druzhok**
  - `hermes_test.exs`: user commands and menu as above; `approvals.destructive_slash_confirm: false` written;
    `onboarding.seen.busy_input_prompt: true` written;
    the seed has no `quick_commands`; the druzhok alias is removed from an existing config, a foreign
    `quick_commands` block is kept; `display.end_user_mode: true` written.
  - `locale_test.exs`: overlay written per language; a name with `"`, `\`, `{`, `}`, a leading `*` or `[`
    produces a file that parses and formats (braces become parentheses); unchanged content not rewritten; refused on a
    symlinked `locales/`; the marker line is present.
  - Overlay audit (reads `hermes-agent/locales/ru.yaml` and `en.yaml` when present, skipped otherwise; run by
    the `update-hermes` skill): every overlay key exists in the bundled catalog; each override's placeholders ⊆
    the bundled key's; every bundled key under the audited roots is overridden or covered by `reviewed.txt`; no
    override value matches `/Hermes|hermes |config\.yaml|doctor|\/login|\/model|\/retry|\/compress|
    провайдер|TTS/` (a guard on our own texts, not the scope definition).
- **fork**: `end_user_mode` on/off for `/new` text, auto-reset text, `/start` reply (idle and busy), busy
  `/status` denied for a gated user only with the flag on, the `(empty)` rewrite localized with the flag on,
  the background notice without the command with the flag on;
  `test_i18n.py` parity with the new key.
- **Manual on the operator's bot** (Telegram Web): menu shows 4 Russian items; `/start`; `/new` (no prompt);
  `/stop` mid-answer; `/status` denied; `/voice` on/off; `/help`; `/whoami`; a forced failure (proxy returns
  500) shows the plain text; `/foo` shows «Такой команды нет»; a second message while the bot is busy shows no
  English hint.

## Rollout

1. Fork commit, pushed; server install as a new hermes dir per the `update-hermes` skill (Step 2), so the
   running bots keep the old dir until restarted.
2. druzhok deploy (menu, confirm off, overlay, flag).
3. Operator's bot first: `sudo ops/druzhok restart igorhermes`, manual checks above. Hermes re-registers the
   Telegram menu on start (`adapter.py:2677`); the fingerprint covers language and payload (`adapter.py:2715`).
4. Then the other bots, one at a time.

**Rollback** has two steps, like batch 2's, because `sync_display_block` keeps unknown `display:` children
(`hermes.ex:284-289`) and `config.yaml` is only seeded when absent: a plain revert would leave
`display.end_user_mode: true` in every config, and the overlay files on disk.
1. Deploy a partial revert: the old menu and user commands, `display.end_user_mode: false` written
   explicitly, `destructive_slash_confirm` left false (harmless), and `Locale.sync` replaced by
   `Locale.remove/1`, which deletes `locales/ru.yaml`/`en.yaml` only when their first line is the druzhok
   marker. Restart the bots (or let them wake).
2. Later, a cleanup commit drops `Locale` and the flag line.
The fork flag defaults off, so the old druzhok on the new fork behaves as today; the old fork ignores the
unknown `display.end_user_mode` key.
