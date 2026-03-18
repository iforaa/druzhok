# Druzhok

Telegram bot backed by OpenCode's multi-model AI runtime.

## Quick Start

1. Install Go 1.25+ and OpenCode (`~/.opencode/bin/opencode`)
2. Configure credentials:
   ```bash
   mkdir -p ~/.config/druzhok
   cat > ~/.config/druzhok/credentials.yaml <<EOF
   telegram:
     bot_token: "YOUR_BOT_TOKEN"
   providers:
     anthropic:
       api_key: "YOUR_ANTHROPIC_KEY"
   EOF
   ```
3. Build and run:
   ```bash
   make run
   ```

## Telegram Commands

| Command | Description |
|---------|-------------|
| `/start` | Start or resume the chat |
| `/stop` | Pause the chat |
| `/reset` | Clear current AI session |
| `/prompt [text]` | Show or set system prompt (admin) |
| `/model <model-id>` | Switch AI model (admin) |

## Skills

Send these messages to trigger built-in workflows:

- `/setup` — guided first-time setup
- `/customize` — change model or system prompt
- `/debug` — troubleshoot issues

## Design Spec

[`docs/superpowers/specs/2026-03-18-druzhok-design.md`](docs/superpowers/specs/2026-03-18-druzhok-design.md)
