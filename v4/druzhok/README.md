# Druzhok v4

Multi-tenant hosting for [Hermes](https://github.com/iforaa/druzhok-hermes) Telegram bots:
one systemd unit + Linux user per bot, an OpenAI-compatible LLM proxy with per-bot
budgets, a LiveView dashboard, and a Telegram "manager bot" for self-service provisioning.

```bash
mix deps.get && mix compile && mix test
HERMES_BIN=/path/to/hermes/.venv/bin/hermes DATABASE_PATH=data/druzhok.db mix phx.server
```

- Operator notes: [`../../CLAUDE.md`](../../CLAUDE.md)
- Design: [`docs/superpowers/specs/2026-08-23-systemd-host-kz-migration-design.md`](../../docs/superpowers/specs/2026-08-23-systemd-host-kz-migration-design.md)
- Server files: [`ops/`](ops/)
