# Druzhok

Multi-tenant Hermes bot hosting. Elixir/Phoenix orchestrator (`v4/druzhok`) runs
one **systemd unit + Linux user per bot** on the KZ server; all LLM traffic goes
through Druzhok's OpenAI-compatible proxy (budgets, metering). No Docker.

## Commits

Always use `/my-commit` for committing changes.

## Critical Rules

- **Never wipe a bot's data dir** (`/data/tenants/<name>`) — it holds memory/identity. Only `BotManager.delete/1` may, and only on explicit user request.
- **Never set HTTP_PROXY/HTTPS_PROXY for bots** — breaks multipart uploads.
- **One Telegram poller per token.** Stop a bot on the old host before starting it elsewhere.
- Hermes source is the fork `github.com/iforaa/druzhok-hermes` (local clone `v4/hermes-agent`, remote `origin`; nousresearch is remote `upstream`). Updates go through the `update-hermes` skill.
- `v4/hermes-agent`, `v4/openclaw`, `v4/*claw` are untracked upstream clones — never `git add -A` from the repo root.

## Layout

```
v4/druzhok/apps/druzhok/      core: BotManager, Host (Systemd|Process), Runtime.Hermes, HealthMonitor(+Probe), ManagerBot, Budget
v4/druzhok/apps/druzhok_web/  Phoenix dashboard + LLM proxy (LlmProxyController) + BotSite plug
v4/druzhok/ops/               druzhok-ctl, hermes@.service, nftables, Caddyfile, bootstrap.sh, smoke.sh
(workspace seed: config.yaml + AGENTS.md come from Runtime.Hermes.workspace_files/1; SOUL.md from the provisioner)
docs/superpowers/specs|plans  design docs (see 2026-08-23-systemd-host-*)
```

`Druzhok.Host` is the process backend: `Host.Systemd` in prod (shells out to `sudo druzhok-ctl`), `Host.Process` in dev/test (spawns `hermes gateway run` as a port; `HERMES_BIN` env or `config :druzhok, :hermes_bin`). Selected by `DRUZHOK_HOST=systemd`.

Prod env (MIX_ENV, DATABASE_PATH, DRUZHOK_HOST, HEX/MIX homes, SECRET_KEY_BASE, PHX_HOST) lives only in `/etc/druzhok/druzhok.env`; `druzhok.service`, `ops/druzhok-run.sh` and `ops/smoke.sh` all source it. One-off prod `mix run` must go through `sudo ops/druzhok-run.sh '<expr>'` (file caps for 0700 tenant dirs).

## Proxy endpoints (all require `Authorization: Bearer <tenant_key>`)

| Endpoint | Upstream |
|---|---|
| `POST /v1/chat/completions`, `/v1/embeddings`, `/v1/images/generations`, `/v1/responses` | OpenRouter |
| `POST /v1/audio/transcriptions` | OpenRouter (Gemini Flash `input_audio`) |
| `POST /v1/audio/speech` | OpenAI TTS |
| `POST /v2/search` | OpenRouter perplexity/sonar (Firecrawl-compatible shape) |

OpenRouter responses have leading whitespace — `String.trim()` before `Jason.decode()`.

## Development (macOS, no Docker)

```bash
cd v4/druzhok
mix deps.get && mix compile && mix test
# run with a real local hermes venv for Host.Process:
HERMES_BIN=/path/to/druzhok-hermes/.venv/bin/hermes DATABASE_PATH=data/druzhok.db mix phx.server
```

## Server (KZ, PS Cloud Almaty)

```bash
ssh ubuntu@195.49.213.8
cd ~/druzhok && git pull
cd v4/druzhok && . ~/.asdf/asdf.sh && MIX_ENV=prod mix compile
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
