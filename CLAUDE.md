# Druzhok

Telegram bot backed by OpenCode's multi-model AI runtime. Each chat gets its own OpenCode session; messages are persisted in SQLite and retried on failure.

## Commits

Always use `/my-commit` skill for committing changes. Never use raw git commit commands.

## Development Commands

```bash
make build   # compile to bin/druzhok
make run     # go run ./cmd/druzhok
make test    # go test ./internal/... -v
make clean   # remove bin/ and data/
```

## Key Files

| Path | Purpose |
|------|---------|
| `cmd/druzhok/main.go` | Entry point — wires all components, command dispatch |
| `internal/config/config.go` | Config loading: credentials file, env overrides, defaults |
| `internal/db/` | SQLite layer — users, chats, messages |
| `internal/opencode/server.go` | Spawns and monitors the OpenCode subprocess |
| `internal/opencode/client.go` | HTTP client for the OpenCode REST API |
| `internal/processor/processor.go` | Sends prompts to OpenCode, persists responses, semaphore concurrency |
| `internal/telegram/bot.go` | Telegram long-poll bot, message dispatch |
| `internal/telegram/handler.go` | Command classification logic |
| `internal/skills/` | Skill loader and registry |
| `skills/` | Built-in skill definitions (SKILL.md files) |
| `docs/superpowers/specs/2026-03-18-druzhok-design.md` | Full design specification |

## Telegram Commands

| Command | Description |
|---------|-------------|
| `/start` | Register chat and resume if paused |
| `/stop` | Pause the chat |
| `/reset` | Delete current OpenCode session and start fresh |
| `/prompt [text]` | Show or set the system prompt (set requires admin) |
| `/model <model-id>` | Switch AI model for this chat (admin only) |

## Skills

Skills are matched against incoming message text via regex triggers defined in each `SKILL.md` front-matter.

| Skill | Trigger | Description |
|-------|---------|-------------|
| `setup` | `/setup` | Guided first-time installation and configuration |
| `customize` | `/customize` | Change chat behavior, system prompt, or model |
| `debug` | `/debug` | Troubleshoot OpenCode server and session issues |

## Configuration

**Credentials file:** `~/.config/druzhok/credentials.yaml`

```yaml
telegram:
  bot_token: "..."
providers:
  anthropic:
    api_key: "..."
  openai:
    api_key: "..."
```

**Environment variable overrides:**

| Variable | Purpose |
|----------|---------|
| `DRUZHOK_TELEGRAM_TOKEN` | Telegram bot token |
| `ANTHROPIC_API_KEY` | Anthropic API key |
| `OPENAI_API_KEY` | OpenAI API key |
| `DRUZHOK_LOG_LEVEL` | Log level: debug / info / warn / error |
| `DRUZHOK_OPENCODE_PORT` | OpenCode server port (default 4096) |

**OpenCode binary:** `/Users/igorkuznetsov/.opencode/bin/opencode` (or first `opencode` found in PATH)
