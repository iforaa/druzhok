# Druzhok

Personal AI assistant as a product. Telegram bot backed by OpenCode's multi-model agent runtime.

## Development

- **Language:** Go
- **Database:** SQLite
- **AI Runtime:** OpenCode (`opencode serve`)
- **Channel:** Telegram

## Commits

Always use `/my-commit` skill for committing changes. Never use raw git commit commands.

## Key Files

| File | Purpose |
|------|---------|
| `docs/superpowers/specs/2026-03-18-druzhok-design.md` | Full design specification |
| `cmd/druzhok/main.go` | Entry point |
| `internal/` | Core packages |
| `skills/` | Built-in skill definitions (markdown) |
| `chats/` | Per-chat customization (runtime) |
