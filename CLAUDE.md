# Druzhok

Multi-tenant Hermes bot hosting. Elixir/Phoenix orchestrator (umbrella at the repo root) runs
one **systemd unit + Linux user per bot** on the KZ server; all LLM traffic goes
through Druzhok's OpenAI-compatible proxy (budgets, metering). No Docker.

## Commits

Always use `/my-commit` for committing changes.

## Critical Rules

- **Never wipe a bot's data dir** (`/data/tenants/<name>`) — it holds memory/identity. Only `BotManager.delete/1` may, and only on explicit user request.
- **Never set HTTP_PROXY/HTTPS_PROXY for bots** — breaks multipart uploads.
- **One Telegram poller per token.** Stop a bot on the old host before starting it elsewhere.
- Hermes source is the fork `github.com/iforaa/druzhok-hermes` (local clone `hermes-agent/`, remote `origin`; nousresearch is remote `upstream`). Updates go through the `update-hermes` skill.
- Tenants get hermes's *user* slash tier (`/new /compress /status /voice`, plus `/help /whoami`); the operator
  (Settings `operator_telegram_id` / `OPERATOR_TELEGRAM_ID`) is admin on every bot. Enforced via upstream
  `platforms.telegram.extra` keys written by `Runtime.Hermes.sync_config/2` on each start — no fork patch.
- `hermes-agent/` is a separate, gitignored git repo (the hermes fork clone) — never `git add` it into druzhok.

## Layout

```
apps/druzhok/      core: BotManager, Host (Systemd|Process), Runtime.Hermes, HealthMonitor(+Probe), ManagerBot, Budget
apps/druzhok_web/  Phoenix dashboard + LLM proxy (LlmProxyController) + BotSite plug
ops/               druzhok-ctl, hermes@.service, nftables, Caddyfile, bootstrap.sh, smoke.sh
hermes-agent/      gitignored clone of the hermes fork (see update-hermes skill)
(workspace seed: config.yaml + AGENTS.md come from Runtime.Hermes.workspace_files/1; SOUL.md from the provisioner)
docs/superpowers/specs|plans  design docs (see 2026-08-23-systemd-host-*)
```

`Druzhok.Host` is the process backend: `Host.Systemd` in prod (shells out to `sudo druzhok-ctl`), `Host.Process` in dev/test (spawns `hermes gateway run` as a port; `HERMES_BIN` env or `config :druzhok, :hermes_bin`). Selected by `DRUZHOK_HOST=systemd`.

Prod env (MIX_ENV, DATABASE_PATH, DRUZHOK_HOST, HEX/MIX homes, SECRET_KEY_BASE, PHX_HOST) lives only in `/etc/druzhok/druzhok.env`; `druzhok.service`, `ops/druzhok-run.sh` and `ops/smoke.sh` all source it. One-off prod `mix run` must go through `sudo ops/druzhok-run.sh '<expr>'` (file caps for 0700 tenant dirs).

## Proxy endpoints (all require `Authorization: Bearer <tenant_key>`)

Chat, search and transcription go to **ruoc-gateway** (`Druzhok.Ruoc`, `LlmProxy.Ruoc`),
one ruoc account per bot (`instances.ruoc_account_id` / `ruoc_api_key`); the balance there is
the only spending limit (402 when empty). Druzhok records tokens and previews only, `cost_cents`
is 0 on those rows. A bot without a ruoc key gets 503 from `LlmAuth` until migrated.
Spec: `docs/superpowers/specs/2026-09-05-ruoc-gateway-migration-design.md`.

| Endpoint | Upstream |
|---|---|
| `POST /v1/chat/completions` | ruoc-gateway `/v1/chat/completions` |
| `POST /v1/audio/transcriptions` | ruoc-gateway `/v1/transcribe` (base64 wav/mp3/ogg) |
| `POST /v2/search` | ruoc-gateway `/v1/search` (Tavily), Firecrawl-shaped reply |
| `POST /v1/embeddings`, `/v1/images/generations`, `/v1/responses` | OpenRouter (unmetered for money) |
| `POST /v1/audio/speech` | OpenAI TTS (unmetered for money) |

ruoc-gateway settings (dashboard Settings page, or `RUOC_URL` / `RUOC_ADMIN_HOST` /
`RUOC_ADMIN_TOKEN` / `RUOC_CATALOG_KEY` env): `BotManager.create/2` provisions a ruoc account
per bot; `BotManager.migrate_to_ruoc/1` (settings-tab button or `mix druzhok.migrate_ruoc <name>`)
moves an old row. Funding is manual in the ruoc console. The model catalog is ruoc's
`GET /v1/models` (`Druzhok.Ruoc.models/0`, default `ruoc-flash`).

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
ssh ubuntu@195.49.213.8
cd ~/druzhok && git pull
. ~/.asdf/asdf.sh && MIX_ENV=prod mix compile
DATABASE_PATH=/data/druzhok/druzhok.db MIX_ENV=prod mix ecto.migrate
sudo systemctl restart druzhok
```

Bots: `sudo druzhok-ctl status|logs|restart <name>`; `journalctl -u hermes@<name> -f`.
Hermes install: `/opt/hermes` (`git pull && uv sync --extra all --extra messaging --extra firecrawl`), then restart bots one at a time — operator's bot first, `ops/smoke.sh`.

Legacy Yandex VM (`ssh -l igor 10.129.0.19`, Docker-based) is kept only as a fallback during migration.

## Debugging

```bash
journalctl -u druzhok --since '5 min ago' | grep -i error | tail -20
sudo druzhok-ctl logs <name> 100
sudo nft list table inet druzhok      # per-bot egress counters
curl -s -H "Authorization: Bearer <tenant_key>" http://127.0.0.1:4000/v1/chat/completions \
  -d '{"model":"x","messages":[{"role":"user","content":"ping"}],"max_tokens":1}'
```
