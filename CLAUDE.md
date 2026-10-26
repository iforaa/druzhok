# Druzhok

Multi-tenant Hermes bot hosting. Elixir/Phoenix orchestrator (umbrella at the repo root) runs
one **systemd unit + Linux user per bot** on the KZ server; all LLM traffic goes
through Druzhok's OpenAI-compatible proxy (forwarding to ruoc-gateway, metering). No Docker.

## Commits

Always use `/my-commit` for committing changes.

## Critical Rules

- **Never wipe a bot's data dir** (`/data/tenants/<name>`) — it holds memory/identity. Only the lifecycle controller may, carrying out a `BotManager.delete/1` request, and only on explicit user request.
- **Bot lifecycle is requests + one controller** (`Druzhok.Lifecycle`, spec `docs/superpowers/specs/2026-10-20-sleep-wake-design.md`).
  `BotManager.start/restart/stop/delete` only write the row (`active`, `start_seq`, `stop_seq`, `delete_requested`);
  one `Lifecycle.Bot` per bot in druzhok.service starts/stops/sleeps/wakes/deletes it. From `druzhok-run.sh` pass
  `wait: true` to get the outcome (`{:ok, _}` / `{:error, reason}` / `{:error, :timeout}`). An active bot whose unit
  is down is started again (backoff 10 s → 15 min), so `druzhok-ctl stop` does not last: stop through
  `BotManager.stop`. Opt-in sleep (`sleep_enabled`, `ops/druzhok set <bot> sleep_enabled=true`): a webhook bot idle for `sleep_idle_minutes`
  (Settings, default 30) is stopped and woken by its next queued update that it would answer
  (`Telegram.Addressed`: group chatter a mention-only bot skips waits, and is delivered on the next wake),
  or 3 min before its next cron run.
- **Never set HTTP_PROXY/HTTPS_PROXY for bots** — breaks multipart uploads.
- **Bot users have no internet**: `ops/nftables-druzhok.nft` allows only the proxy, DNS and Telegram's CIDRs. Anything a bot needs from the web goes through the proxy (search, `/v2/scrape`).
- **One Telegram poller per token.** Stop a bot on the old host before starting it elsewhere.
- Hermes source is the fork `github.com/iforaa/druzhok-hermes` (local clone `hermes-agent/`, remote `origin`; nousresearch is remote `upstream`). Updates go through the `update-hermes` skill.
- Tenants get hermes's *user* slash tier (`/start /new /stop /voice`, plus `/help /whoami`); the operator
  (Settings `operator_telegram_id` / `OPERATOR_TELEGRAM_ID`) is admin on every bot. Enforced via upstream
  `platforms.telegram.extra` keys written by `Runtime.Hermes.sync_config/2` on each start — no fork patch.
- **Telegram delivery is per bot** (`instances.telegram_mode`): `polling` (hermes long-polls) or `webhook`
  (Telegram → `POST /telegram/webhook/<bot>` → `telegram_updates` queue → `Druzhok.Telegram.Relay` →
  hermes's PTB server on `127.0.0.1:20000+id`). New bots start in webhook mode when a public host is set (`PHX_HOST`; `BotManager.create`). Switch with
  `sudo ops/druzhok-run.sh 'IO.inspect(Druzhok.Telegram.Webhook.set_mode("<bot>", "webhook"))'` then
  `BotManager.restart`; leaving webhook mode is refused while rows are queued (`force: true` drops them).
  Only a bot's own uid may answer druzhok from its port (nft `bot_webhook` `uid . port`, written by
  `druzhok-ctl`), and the relay checks the listener's uid before every delivery. No systemd bind lock:
  this box's systemd lacks BPF_FRAMEWORK, so `SocketBindAllow/Deny` are silently ignored.
  Every controller stop pauses the bot's relay first and waits out a delivery in flight; a successful start lifts
  every pause but `wrong_owner`. The relay holds updates for a bot that is stopped or asleep. Spec:
  `docs/superpowers/specs/2026-10-20-telegram-webhook-relay-design.md`.
- `hermes-agent/` is a separate, gitignored git repo (the hermes fork clone) — never `git add` it into druzhok.

## Layout

```
apps/druzhok/      core: BotManager, Host (Systemd|Process), Runtime.Hermes, ManagerBot, Lifecycle, CLI
apps/druzhok_web/  Phoenix, no UI: LLM proxy (LlmProxyController), Telegram webhook, /internal/fetch, BotSite plug
ops/               druzhok-ctl, hermes@.service, nftables, Caddyfile, bootstrap.sh, smoke.sh
hermes-agent/      gitignored clone of the hermes fork (see update-hermes skill)
(workspace seed: config.yaml comes from Runtime.Hermes.workspace_files/1; SOUL.md from Runtime.Hermes.Voice.sync_soul/2; no AGENTS.md;
 locales/{ru,en}.yaml, druzhok's wording for hermes's fixed replies, from Runtime.Hermes.Locale, sources priv/hermes_locale)
docs/superpowers/specs|plans  design docs (see 2026-08-23-systemd-host-*)
```

`Druzhok.Host` is the process backend: `Host.Systemd` in prod (shells out to `sudo druzhok-ctl`), `Host.Process` in dev/test (spawns `hermes gateway run` as a port; `HERMES_BIN` env or `config :druzhok, :hermes_bin`). Selected by `DRUZHOK_HOST=systemd`.

Prod env (MIX_ENV, DATABASE_PATH, DRUZHOK_HOST, HEX/MIX homes, SECRET_KEY_BASE, PHX_HOST) lives only in `/etc/druzhok/druzhok.env`; `druzhok.service`, `ops/druzhok-run.sh` and `ops/smoke.sh` all source it. One-off prod `mix run` must go through `sudo ops/druzhok-run.sh '<expr>'` (file caps for 0700 tenant dirs).

## Proxy endpoints (all require `Authorization: Bearer <tenant_key>`)

Chat, search, transcription and image generation go to **ruoc-gateway** (`Druzhok.Ruoc`, `LlmProxy.Ruoc`),
one ruoc account per bot (`instances.ruoc_account_id` / `ruoc_api_key`); the balance there is
the only spending limit (402 when empty). Druzhok records tokens and previews only, `cost_cents`
is 0 on those rows. A bot without a ruoc key gets 503 from `LlmAuth`. A 402 (plan limit reached)
on chat is answered as a normal 200 completion carrying `LlmProxy.BalanceNotice` in the bot's
language, because hermes's own 402 text tells tenants to add provider credits and switch `/model`;
hermes's auxiliary calls (`LlmProxy.AuxShapes`: no tools, and no system message or a known aux
prompt) keep the real 402. What a bot is told about itself (SOUL.md, `agent.system_prompt`
product rules, the Russian Telegram hint) is `Runtime.Hermes.Voice`, spec
`docs/superpowers/specs/2026-10-25-bot-voice-design.md`. What hermes itself prints (menu `/new /stop /voice /help`, `/start`
greeting, failures; locale overlay + fork flag `display.end_user_mode`) is `Runtime.Hermes.Locale`, spec
`docs/superpowers/specs/2026-10-26-tenant-chat-surface-design.md`.
Spec: `docs/superpowers/specs/2026-09-05-ruoc-gateway-migration-design.md`.

| Endpoint | Upstream |
|---|---|
| `POST /v1/chat/completions` | ruoc-gateway `/v1/chat/completions` |
| `POST /v1/audio/transcriptions` | ruoc-gateway `/v1/transcribe` (base64 wav/mp3/ogg) |
| `POST /v2/search` | ruoc-gateway `/v1/search` (Tavily), Firecrawl-shaped reply |
| `POST /v2/scrape` | ruoc-gateway `/v1/fetch`, which routes back to druzhok `POST /internal/fetch` (shared secret `fetch_secret` / `FETCH_SECRET`); `Druzhok.Fetch` reads the page (SSRF policy, 5 MiB, 30 s) and the Python worker at `FETCH_WORKER_BIN` (venv `/opt/druzhok-fetch`, `apps/druzhok/priv/fetch-worker`) turns it into markdown. Priced per page in ruoc (`ruocd fetch setup -rub 0`, free at launch) |
| `POST /v1/images/generations` | ruoc-gateway `/v1/images` (per-image price, model = `instances.image_gen_model`, nil = ruoc default; catalogue from `GET /v1/images/models` via `Druzhok.Ruoc.image_models/0`) |
| `POST /v1/embeddings` | ruoc-gateway `/v1/embeddings` (kind `embedding`, per 1M input tokens, free at launch), computed upstream by ruoc. Bots send entry `ruoc-embed-gemini` (`Runtime.Hermes` `@embedding_model`/`@embedding_dim`, google/gemini-embedding-001 3072-d via OpenRouter, since 2026-10-22; `ruoc-embed-e5-large` before, whose one provider hung). ruoc hedges batches of ≤8 texts (`EMBED_HEDGE_AFTER` 2.5 s, `EMBED_ATTEMPT_TIMEOUT` 5 s). Changing the model = new ruoc entry + `@embedding_model`/`@embedding_dim` + `druzhok-ctl exec <bot> mnemosyne reindex --yes` per bot; a dimension mismatch makes Mnemosyne fall back to keyword recall, never corrupts. `MNEMOSYNE_DATA_DIR` must be `<tenant>/mnemosyne/data` (the plugin hardcodes that path, the CLI follows the variable). Used by the Mnemosyne memory provider (`instances.memory_provider`); spec `docs/superpowers/specs/2026-09-06-mnemosyne-memory-design.md`, eval `ops/embed-eval` |
| `POST /v1/audio/speech` | OpenAI TTS (unmetered for money) |

ruoc-gateway settings: `RUOC_URL` / `RUOC_CATALOG_KEY` env (or `ops/druzhok settings set`), and
`RUOC_PARTNER_TOKEN` in `/etc/druzhok/druzhok.env` **only** (never a settings row). Druzhok is a ruoc
*partner*: account calls go to ruoc's `/partner/*` routes (no admin token, no `Host` trick), which see
only druzhok's own accounts. `BotManager.create/2` provisions a ruoc account per bot with
`external_ref` `<name>:<owner tg id or ->` (a repeat gets 409 `account_exists` and the key is reissued;
a lost reply is retried once; 429 `partner_quota` → «Сейчас создаётся слишком много ботов…», raise with
`ruocd partner limit`), under a per-name lock. The account joins the partner's default plan
(`ruocd partner plan`), else the global **default plan** on the ruoc console's Plans page (ruoc issues the
plan's credit each period, no payment gateway yet). A delete suspends the account; if that fails the row
stays (`delete_error`, `delete_failures`) and the controller retries on the start backoff.
`sudo ops/druzhok ruoc-check [--suspend-orphans]` compares ruoc's partner accounts with `instances`
(orphans, missing/suspended accounts, ref mismatches, stuck deletes; exit 1 when any). The old
`ruoc_admin_*` settings rows are unused, kept for rollback only. Spec: ruoc-gateway
`docs/superpowers/specs/2026-10-22-partner-access-design.md`. Extra funding and plan
changes happen in the ruoc console; the manager bot and `ops/druzhok show` only show plan + renewal
date from `GET /v1/balance` (`Druzhok.Ruoc.balance/1`). Bot cabinet (ruoc-gateway spec
`2026-10-24-telegram-mini-app-design.md`): ruoc serves a Telegram Mini App at `oldey.dev/tg/` where a bot's
owner sees its account and pays for druzhok's plans (managed in ruoc's Pricing tab, «Партнёр» = druzhok).
`Druzhok.Cabinet` (one GenServer, casts only) binds each bot at ruoc (`PUT /partner/accounts/{id}/telegram`)
and sets the owner's «Кабинет» menu button on every start/wake when something changed
(`instances.cabinet_binding/cabinet_url/cabinet_menu_set`); the button is retried on the owner's first private
message, since Telegram refuses it before the owner opened the bot. A chat 402 also sends the owner an
«Открыть кабинет» button, at most every 6 h. `sudo ops/druzhok bind-cabinet [<bot>]` binds now; `--off`
restores the default button and sets `cabinet_off`, which nothing undoes but a plain `bind-cabinet`. An owner
or language change rebinds and resets the old owner's button. The model catalog is ruoc's
`GET /v1/models` (`Druzhok.Ruoc.models/0`, default `ruoc-flash`).

Bot panel (spec `docs/superpowers/specs/2026-10-24-bot-panel-design.md`): with `PHX_HOST` set, «Кабинет» opens
druzhok's own Mini App, `https://<PHX_HOST>/app/?bot=<bot_id>` (source `apps/druzhok_web/assets/app`, built by
`ops/build-app.sh` into the committed `priv/static/app`). Tabs Главная, Память, Счёт, Ещё (own dark/light palette);
the bot, files and invites (`GET /app/api/invites`, ruoc `/v1/referrals` → superbot links) are read only and
served by druzhok (`Druzhok.Panel`, `PanelController`); «Поддержка» shows when Settings `support_url` (https)
is set. Owners change language, timezone, group mode, pictures and site in Ещё (`POST /app/api/settings`,
allowlist `Druzhok.Panel.Settings`; spec `docs/superpowers/specs/2026-10-26-panel-controls-design.md`): a save
never restarts or wakes the bot, it bumps `settings_seq`, and the lifecycle controller restarts an awake bot
at a quiet moment (no update/proxy call for 60 s, no turn, no child process; never forced) while a wake or any
start applies it (`settings_applied_seq`). «Удалить бота» (`POST /app/api/delete`) only sends the owner a
`pdel:<token>` confirm in the superbot (10 min), since the bot itself could phish panel init data. For a
panel-ready bot (`Onboarding.panel_ready?`) the superbot drops 🎨/🗑 and answers old buttons with an alert. Счёт calls ruoc's `/tg/api/*` cross-origin at `RUOC_SITE_URL` (default
`https://oldey.dev`; ruoc must list druzhok in `TG_PANEL_ORIGINS`). `/app` answers only with Caddy's
`X-Druzhok-Edge` header (`DRUZHOK_EDGE_SECRET`, env only; bots reach :4000 directly), and the API checks Telegram's
Ed25519 signature plus the bot-token HMAC and the owner (`Plugs.PanelAuth`). Files are read through
`Druzhok.TenantFiles` (no symlink below the tenant dir, verified descriptor); directory listings run as the bot's
uid (`Druzhok.Panel.Lister`, `druzhok-ctl exec` + GNU find). `Druzhok.Cabinet` moves each button to the panel on
the next start, wake, owner message or `bind-cabinet`.

The superbot is invite-only: `admissions` (`Druzhok.Admissions`) records who may create a bot,
written when a bot is created with the code's first characters as the hint (or `owner` when no code
was used), and the code itself is spent by ruoc in `POST /partner/accounts`. The operator issues
referral codes to a bot's account from the ruoc console account page, and «🎁 Пригласить» reads them
via `GET /v1/referrals`. Two bots per person (`@max_bots_per_user 2`), the operator excepted. Spec:
`docs/superpowers/specs/2026-09-19-referral-invites-design.md`.


## Development (macOS, no Docker)

```bash
mix deps.get && mix compile && mix test
mix test --cover        # enforces per-app thresholds set in each mix.exs; raise them when coverage grows
MIX_ENV=test mix ecto.migrate   # after pulling new migrations (test DB is data/druzhok_test.db)
# run with a real local hermes venv for Host.Process:
HERMES_BIN=$PWD/hermes-agent/.venv/bin/hermes DATABASE_PATH=data/druzhok.db mix phx.server
```

## Server (KZ, PS Cloud Almaty)

```bash
# ~/druzhok on the box is an rsync target (symlink to /data/home-ubuntu/druzhok-new), not a git checkout
ops/build-app.sh   # only when apps/druzhok_web/assets/app changed; the build output is committed
rsync -az --delete --exclude=_build --exclude=deps --exclude=node_modules apps config ops mix.exs mix.lock .tool-versions ubuntu@195.49.213.8:~/druzhok/
ssh ubuntu@195.49.213.8
. ~/.asdf/asdf.sh; set -a; . /etc/druzhok/druzhok.env; set +a
cd ~/druzhok && MIX_ENV=prod mix compile
MIX_ENV=prod mix ecto.migrate          # DATABASE_PATH comes from druzhok.env
sudo systemctl restart druzhok
```

Operator CLI (replaces the dashboard, spec `docs/superpowers/specs/2026-10-21-dashboard-removal-design.md`):
`sudo ops/druzhok help` — `list`, `show <bot>`, `set <bot> key=value…` (restarts a running bot when the field
needs it, `Druzhok.BotSettings`; `value=-` reads stdin for secrets), `start|stop|restart <bot>` (waits),
`users|allow|disallow|approve`, `ruoc-check`, `settings [set key=value…]`. Dev: `mix druzhok …`.
Units: `sudo druzhok-ctl status|logs <name>`; `journalctl -u hermes@<name> -f`.
All bots share `system-hermes.slice` (`ops/system-hermes.slice`: MemoryHigh 4.5G, MemoryMax 5G; per-bot 800M/1G in `hermes@.service`). Changing it applies live on `daemon-reload`.
Hermes install: `/opt/hermes` is a symlink to `/data/opt/hermes-<version>` (one dir per version, rsynced from `hermes-agent/`, not a git checkout; Python 3.14 from uv under `/data/opt/uv-python` since 0.22; recipe in the `update-hermes` skill). Bots move onto a new dir one at a time through druzhok (`sudo ops/druzhok restart <bot>`, not `druzhok-ctl restart`, which skips config sync) — operator's bot first, `ops/smoke.sh`.

Legacy Yandex VM (`ssh -l igor 10.129.0.19`, Docker-based) is kept only as a fallback during migration.

## Debugging

```bash
journalctl -u druzhok --since '5 min ago' | grep -i error | tail -20
sudo druzhok-ctl logs <name> 100
sudo nft list table inet druzhok      # per-bot egress counters
curl -s -H "Authorization: Bearer <tenant_key>" http://127.0.0.1:4000/v1/chat/completions \
  -d '{"model":"x","messages":[{"role":"user","content":"ping"}],"max_tokens":1}'
```
