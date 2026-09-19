# Druzhok

Multi-tenant Hermes bot hosting. Elixir/Phoenix orchestrator (umbrella at the repo root) runs
one **systemd unit + Linux user per bot** on the KZ server; all LLM traffic goes
through Druzhok's OpenAI-compatible proxy (budgets, metering). No Docker.

## Commits

Always use `/my-commit` for committing changes.

## Critical Rules

- **Never wipe a bot's data dir** (`/data/tenants/<name>`) — it holds memory/identity. Only `BotManager.delete/1` may, and only on explicit user request.
- **Never set HTTP_PROXY/HTTPS_PROXY for bots** — breaks multipart uploads.
- **Bot users have no internet**: `ops/nftables-druzhok.nft` allows only the proxy, DNS and Telegram's CIDRs. Anything a bot needs from the web goes through the proxy (search, `/v2/scrape`).
- **One Telegram poller per token.** Stop a bot on the old host before starting it elsewhere.
- Hermes source is the fork `github.com/iforaa/druzhok-hermes` (local clone `hermes-agent/`, remote `origin`; nousresearch is remote `upstream`). Updates go through the `update-hermes` skill.
- Tenants get hermes's *user* slash tier (`/new /compress /status /voice`, plus `/help /whoami`); the operator
  (Settings `operator_telegram_id` / `OPERATOR_TELEGRAM_ID`) is admin on every bot. Enforced via upstream
  `platforms.telegram.extra` keys written by `Runtime.Hermes.sync_config/2` on each start — no fork patch.
- `hermes-agent/` is a separate, gitignored git repo (the hermes fork clone) — never `git add` it into druzhok.

## Layout

```
apps/druzhok/      core: BotManager, Host (Systemd|Process), Runtime.Hermes, ManagerBot, Budget
apps/druzhok_web/  Phoenix dashboard + LLM proxy (LlmProxyController) + BotSite plug
ops/               druzhok-ctl, hermes@.service, nftables, Caddyfile, bootstrap.sh, smoke.sh
hermes-agent/      gitignored clone of the hermes fork (see update-hermes skill)
(workspace seed: config.yaml + AGENTS.md come from Runtime.Hermes.workspace_files/1; SOUL.md from the provisioner)
docs/superpowers/specs|plans  design docs (see 2026-08-23-systemd-host-*)
```

`Druzhok.Host` is the process backend: `Host.Systemd` in prod (shells out to `sudo druzhok-ctl`), `Host.Process` in dev/test (spawns `hermes gateway run` as a port; `HERMES_BIN` env or `config :druzhok, :hermes_bin`). Selected by `DRUZHOK_HOST=systemd`.

Prod env (MIX_ENV, DATABASE_PATH, DRUZHOK_HOST, HEX/MIX homes, SECRET_KEY_BASE, PHX_HOST) lives only in `/etc/druzhok/druzhok.env`; `druzhok.service`, `ops/druzhok-run.sh` and `ops/smoke.sh` all source it. One-off prod `mix run` must go through `sudo ops/druzhok-run.sh '<expr>'` (file caps for 0700 tenant dirs).

## Proxy endpoints (all require `Authorization: Bearer <tenant_key>`)

Chat, search, transcription and image generation go to **ruoc-gateway** (`Druzhok.Ruoc`, `LlmProxy.Ruoc`),
one ruoc account per bot (`instances.ruoc_account_id` / `ruoc_api_key`); the balance there is
the only spending limit (402 when empty). Druzhok records tokens and previews only, `cost_cents`
is 0 on those rows. A bot without a ruoc key gets 503 from `LlmAuth` until migrated. A 402 (empty
balance) on chat is answered as a normal 200 completion carrying `LlmProxy.BalanceNotice` in the bot's
language, because hermes's own 402 text tells tenants to add provider credits and switch `/model`.
Spec: `docs/superpowers/specs/2026-09-05-ruoc-gateway-migration-design.md`.

| Endpoint | Upstream |
|---|---|
| `POST /v1/chat/completions` | ruoc-gateway `/v1/chat/completions` |
| `POST /v1/audio/transcriptions` | ruoc-gateway `/v1/transcribe` (base64 wav/mp3/ogg) |
| `POST /v2/search` | ruoc-gateway `/v1/search` (Tavily), Firecrawl-shaped reply |
| `POST /v2/scrape` | ruoc-gateway `/v1/fetch`, which routes back to druzhok `POST /internal/fetch` (shared secret `fetch_secret` / `FETCH_SECRET`); `Druzhok.Fetch` reads the page (SSRF policy, 5 MiB, 30 s) and the Python worker at `FETCH_WORKER_BIN` (venv `/opt/druzhok-fetch`, `apps/druzhok/priv/fetch-worker`) turns it into markdown. Priced per page in ruoc (`ruocd fetch setup -rub 0`, free at launch) |
| `POST /v1/images/generations` | ruoc-gateway `/v1/images` (per-image price, model = `instances.image_gen_model`, nil = ruoc default; catalogue from `GET /v1/images/models` via `Druzhok.Ruoc.image_models/0`) |
| `POST /v1/embeddings` | ruoc-gateway `/v1/embeddings` (kind `embedding`, entry `ruoc-embed`, per 1M input tokens, free at launch) → druzhok `POST /internal/embed` (same `FETCH_SECRET`) → `Druzhok.Embed.Worker` + Python ONNX worker (`EMBED_WORKER_BIN`, `EMBED_MODEL_DIR`, multilingual-e5-small, `apps/druzhok/priv/embed-worker`). Used by the Mnemosyne memory provider (`instances.memory_provider`, settings tab); spec `docs/superpowers/specs/2026-09-06-mnemosyne-memory-design.md`, eval `ops/embed-eval` |
| `POST /v1/responses` | OpenRouter (unmetered for money) |
| `POST /v1/audio/speech` | OpenAI TTS (unmetered for money) |

ruoc-gateway settings (dashboard Settings page, or `RUOC_URL` / `RUOC_ADMIN_HOST` /
`RUOC_ADMIN_TOKEN` / `RUOC_CATALOG_KEY` env): `BotManager.create/2` provisions a ruoc account
per bot, which joins the **default plan** set on the ruoc console's Plans page (ruoc issues the
plan's credit each period, no payment gateway yet); `BotManager.migrate_to_ruoc/1` (settings-tab
button or `mix druzhok.migrate_ruoc <name>`) moves an old row, unfunded. Extra funding and plan
changes happen in the ruoc console; the manager bot and the settings tab only show plan + renewal
date from `GET /v1/balance` (`Druzhok.Ruoc.balance/1`). The model catalog is ruoc's
`GET /v1/models` (`Druzhok.Ruoc.models/0`, default `ruoc-flash`).

The superbot is invite-only: `admissions` (`Druzhok.Admissions`) records who may create a bot, written when ruoc accepted their code (`POST /admin/accounts` with `invite`); the operator issues referral codes to a bot's account from the ruoc console account page, and «🎁 Пригласить» reads them via `GET /v1/referrals`. One bot per person (`@max_bots_per_user 1`). Spec: `docs/superpowers/specs/2026-09-19-referral-invites-design.md`.

OpenRouter responses have leading whitespace — `String.trim()` before `Jason.decode()`.

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
rsync -az --delete --exclude=_build --exclude=deps apps config ops mix.exs mix.lock .tool-versions ubuntu@195.49.213.8:~/druzhok/
ssh ubuntu@195.49.213.8
. ~/.asdf/asdf.sh; set -a; . /etc/druzhok/druzhok.env; set +a
cd ~/druzhok && MIX_ENV=prod mix compile
MIX_ENV=prod mix ecto.migrate          # DATABASE_PATH comes from druzhok.env
sudo systemctl restart druzhok
```

Bots: `sudo druzhok-ctl status|logs|restart <name>`; `journalctl -u hermes@<name> -f`.
Hermes install: `/opt/hermes` → `/data/opt/hermes`, rsynced from `hermes-agent/` (not a git checkout; recipe in the `update-hermes` skill), then restart bots one at a time through druzhok (`BotManager.restart` via `druzhok-run.sh`, not `druzhok-ctl restart`, which skips config sync) — operator's bot first, `ops/smoke.sh`.

Legacy Yandex VM (`ssh -l igor 10.129.0.19`, Docker-based) is kept only as a fallback during migration.

## Debugging

```bash
journalctl -u druzhok --since '5 min ago' | grep -i error | tail -20
sudo druzhok-ctl logs <name> 100
sudo nft list table inet druzhok      # per-bot egress counters
curl -s -H "Authorization: Bearer <tenant_key>" http://127.0.0.1:4000/v1/chat/completions \
  -d '{"model":"x","messages":[{"role":"user","content":"ping"}],"max_tokens":1}'
```
