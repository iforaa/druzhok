# Druzhok — Design Specification

Personal AI assistant as a product. Telegram bot backed by OpenCode's multi-model agent runtime. Designed for single-user MVP with a clear path to multi-tenant SaaS.

## Context

Inspired by [NanoClaw](https://github.com/qwibitai/nanoclaw) — a personal Claude assistant that runs agents in isolated containers. Druzhok replaces the Claude Agent SDK with [OpenCode](https://opencode.ai), gaining multi-model support (Claude, GPT, Gemini, local models) and a rich programmatic SDK.

### Key Decisions

- **Go** as the language (native to OpenCode, strong for future containerization)
- **Telegram** as the only channel (for now)
- **No containers** for MVP — `opencode serve` runs directly on the host
- **SQLite** in WAL mode for persistence
- **User** as a first-class concept from day one (even with a single user)
- **Per-chat customization** via system prompts stored in the database (equivalent to NanoClaw's per-group CLAUDE.md)
- **Skills** as markdown instruction files (same pattern as NanoClaw)
- **Structured logging** via Go's `slog` standard library

### Prerequisites

Before implementation, spike a minimal Go program that:
1. Starts `opencode serve`
2. Creates a session via the Go SDK
3. Sends one prompt and receives a response

This verifies the SDK API surface matches what this spec assumes. Document any deviations.

## Architecture

```
Telegram Bot API
    | webhook/long-poll
    v
+-------------------------------+
|          Druzhok               |
|                                |
|  +----------+   +-----------+ |
|  | Telegram  |-->| Message   | |
|  | Channel   |   | Processor | |
|  +----------+   +-----+-----+ |
|                       |        |
|  +----------+   +-----+-----+ |
|  | SQLite   |<--| Agent     | |
|  | Store    |   | Manager   | |
|  +----------+   +-----+-----+ |
|                       |        |
|               +-------+------+ |
|               | OpenCode     | |
|               | Client       | |
|               +-------+------+ |
+-------------------------------|+
                        |
                        v
                 opencode serve
              (subprocess, configurable port)
```

Single Go binary that:
1. Starts `opencode serve` as a managed subprocess
2. Connects via the Go SDK (`opencode-sdk-go`)
3. Runs the Telegram bot
4. Manages SQLite state

### Concurrency Model

Each chat's prompt execution runs in its own goroutine. A semaphore limits concurrent OpenCode prompts to N (configurable, default 5). This prevents one slow chat from blocking others.

```go
// Simplified model
sem := make(chan struct{}, config.MaxConcurrentPrompts)

func processMessage(chat Chat, msg Message) {
    sem <- struct{}{}        // acquire slot
    defer func() { <-sem }() // release slot
    // ... send prompt to OpenCode, wait for response
}
```

### Logging

Structured logging via Go's `slog` package. Log levels:
- **ERROR**: OpenCode crashes, Telegram API failures, DB errors
- **WARN**: Rate limits, session recovery, retries
- **INFO**: Message processed, session created, server started
- **DEBUG**: Full prompts, OpenCode responses, SDK calls

`opencode serve` subprocess stdout/stderr captured and logged at DEBUG level.

## Data Model

```sql
CREATE TABLE users (
    id              TEXT PRIMARY KEY,
    tg_user_id      INTEGER NOT NULL UNIQUE,
    name            TEXT NOT NULL,
    is_admin        INTEGER NOT NULL DEFAULT 0,
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE chats (
    id              TEXT PRIMARY KEY,
    user_id         TEXT NOT NULL REFERENCES users(id),
    tg_chat_id      INTEGER NOT NULL UNIQUE,
    oc_session_id   TEXT,
    name            TEXT NOT NULL DEFAULT '',
    system_prompt   TEXT NOT NULL DEFAULT '',
    model           TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'active',
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE messages (
    id              TEXT PRIMARY KEY,
    chat_id         TEXT NOT NULL REFERENCES chats(id),
    tg_message_id   INTEGER,
    role            TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
    text            TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK(status IN ('pending', 'processing', 'completed', 'sent', 'failed')),
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_messages_status ON messages(status);
CREATE INDEX idx_messages_chat ON messages(chat_id, created_at);
CREATE INDEX idx_chats_tg ON chats(tg_chat_id);
```

SQLite opened in WAL mode with a single writer connection for safe concurrent reads.

### Message Status Flow

Status tracks the **user message → AI response** lifecycle:

```
User message saved (role: user, status: pending)
  → Processing started (status: processing)
  → OpenCode responds → save assistant message (role: assistant, status: completed)
  → User message updated (status: completed)
  → Response sent to Telegram → assistant message (status: sent)
```

On failure at any step, status stays at its current value. The polling loop retries on the next cycle.

### User Creation

On first `/start` from a Telegram user, Druzhok creates a user record from the Telegram user's ID and display name. The first user to `/start` is automatically the admin (`is_admin = 1`). Admin status is required for privileged commands (`/prompt`, `/model`, `/reset`).

## Package Structure

```
druzhok/
├── cmd/
│   └── druzhok/
│       └── main.go              # Entry point
├── internal/
│   ├── config/
│   │   └── config.go            # Env vars, credentials, validation
│   ├── db/
│   │   ├── db.go                # SQLite connection, migrations (CREATE TABLE IF NOT EXISTS)
│   │   ├── users.go             # User CRUD
│   │   ├── chats.go             # Chat CRUD, session mapping
│   │   └── messages.go          # Message storage, status transitions
│   ├── opencode/
│   │   ├── server.go            # Manage opencode serve lifecycle
│   │   └── client.go            # Go SDK wrapper
│   ├── telegram/
│   │   ├── bot.go               # Telegram bot setup, polling
│   │   ├── handler.go           # Message/command handler
│   │   └── sender.go            # Response delivery, message splitting
│   ├── processor/
│   │   └── processor.go         # Message processing, prompt building, concurrency
│   └── skills/
│       ├── loader.go            # Discover and parse skill markdown
│       └── registry.go          # Skill registry
├── skills/                      # Built-in skill definitions
│   ├── setup/
│   │   └── SKILL.md
│   ├── customize/
│   │   └── SKILL.md
│   └── debug/
│       └── SKILL.md
├── data/
│   └── druzhok.db
├── go.mod
├── go.sum
└── Makefile
```

Migrations use `CREATE TABLE IF NOT EXISTS`. Future schema changes use idempotent `ALTER TABLE ... ADD COLUMN` wrapped in error handling.

## OpenCode Integration

### Server Lifecycle

Druzhok manages `opencode serve` as a child process:

1. **Start:** Spawn `opencode serve --port <configurable> --hostname 127.0.0.1` in the Druzhok project root (where `.opencode/` lives). Port defaults to 4096, configurable via `DRUZHOK_OPENCODE_PORT`.
2. **Health:** Poll `GET /global/health` with exponential backoff until ready.
3. **Auth:** Set provider API keys via the SDK's auth methods.
4. **Monitor:** Health check every 30s, auto-restart on crash (max 3 retries, exponential backoff).
5. **Stop:** SIGTERM on shutdown, wait 10s, SIGKILL if needed.

Subprocess stdout/stderr captured and logged via `slog` at DEBUG level.

### Session Management

Each Telegram chat maps to one OpenCode session:

```
Chat "Family" (tg_chat_id: -100123) → OpenCode session "sess_abc123"
Chat "Work"   (tg_chat_id: -100456) → OpenCode session "sess_def456"
```

New chats get a new session via `client.Session.Create()`. The mapping is stored in `chats.oc_session_id`.

### Per-Chat System Prompt

Each chat has a `system_prompt` stored in the database (single source of truth). Prepended to every prompt sent to OpenCode:

```go
func buildPrompt(chat Chat, userMessage string) string {
    if chat.SystemPrompt != "" {
        return fmt.Sprintf(
            "<system-context>\n%s\n</system-context>\n\n%s",
            chat.SystemPrompt,
            userMessage,
        )
    }
    return userMessage
}
```

The agent can request system prompt changes via a tool/command that writes to the database, not the filesystem. This keeps the DB as the single source of truth.

### Prompt Execution

MVP uses synchronous prompts (each in its own goroutine, limited by semaphore):

```go
result := client.Session.Prompt({
    Path: { ID: sessionID },
    Body: {
        Parts: []Part{{ Type: "text", Text: prompt }},
    },
})
```

Async + SSE streaming is a future enhancement for better UX.

### Agent Configuration

OpenCode agents configured via `.opencode/agents/`:

```
.opencode/
├── agents/
│   └── default.md        # General-purpose assistant
└── config.json           # Provider and model defaults
```

Per-chat agent switching (`/agent <name>`) deferred to Phase 2.

## Skills System

### Skill Format

Markdown files with YAML frontmatter (same pattern as NanoClaw):

```yaml
---
name: setup
description: First-time Druzhok installation and configuration
triggers:
  - "^/setup$"
  - "help me set up"
---
# Instructions for the AI to follow...
```

Skills are instructions for the AI agent, not executables.

### Built-in Skills

Shipped with Druzhok (`skills/`):
- `/setup` — guided first-time installation
- `/customize` — change chat behavior, system prompt, model
- `/debug` — troubleshooting (logs, OpenCode health, session state)

### Message Routing Priority

When a message arrives from Telegram:

1. **Built-in commands** — checked first, handled directly by Druzhok without OpenCode:

| Command | Action |
|---------|--------|
| `/start` | Register chat, create user/chat DB records |
| `/stop` | Pause chat |
| `/reset` | Clear OpenCode session, start fresh |
| `/prompt` | Show current system prompt |
| `/prompt <text>` | Set new system prompt (admin only) |
| `/model <id>` | Switch model for this chat (admin only) |

2. **Skill triggers** — if the message matches a skill's trigger pattern, load the skill markdown and send it as a prompt to OpenCode along with the user's message.

3. **Regular message** — sent directly to the chat's OpenCode session.

### Skill Invocation

```
User sends "/debug" in Telegram
  → handler.go checks built-in commands → no match
  → handler.go checks skill triggers → matches skills/debug/SKILL.md
  → Loads skill content
  → Sends as prompt to OpenCode session:
    "{skill content}\n\nUser request: /debug"
  → Agent follows instructions, responds
  → Response sent back to Telegram
```

Skills with arguments:
```
"/customize speak only in Russian"
  → "{skill content}\n\nUser request: speak only in Russian"
```

## Credential Management

### Storage

```
~/.config/druzhok/
├── config.yaml          # Non-secret config (default model, timezone, etc.)
└── credentials.yaml     # Secrets (0600 permissions)
```

Separate from the project directory. Never committed to git.

```yaml
# credentials.yaml
telegram:
  bot_token: "123456:ABC-DEF..."

providers:
  anthropic:
    api_key: "sk-ant-..."
  openai:
    api_key: "sk-..."
```

### Priority

1. Environment variables (`DRUZHOK_TELEGRAM_TOKEN`, `ANTHROPIC_API_KEY`)
2. `~/.config/druzhok/credentials.yaml`
3. `.env` file in project directory

### First-Run Setup

Interactive CLI on first run:
```
$ druzhok

Welcome to Druzhok! Let's get you set up.

1. Telegram Bot Token required.
   → Create a bot with @BotFather on Telegram
   → Enter token: ___

2. OpenCode provider setup.
   → Which AI provider? (anthropic/openai/google/local)
   → Enter API key: ___

3. Starting...
   ✓ OpenCode server running
   ✓ Telegram bot connected as @YourBotName
   ✓ Send a message to your bot to start!
```

Runtime credential changes via Telegram deferred to Phase 2 (security concern: keys visible in chat history).

## Error Handling and Reliability

### OpenCode Server Failures

```
opencode serve crashes
  → Health check detects failure
  → Auto-restart (up to 3 attempts, exponential backoff)
  → If still down → pause all chats, alert admin via Telegram
  → Incoming messages queued in SQLite
  → On recovery → drain queue in order
```

### Message Queue

Messages are never lost:

1. Telegram message arrives → saved to SQLite (`status: pending`)
2. Processor picks it up (in a goroutine) → `status: processing`
3. OpenCode responds → `status: completed`, store assistant response
4. Sent to Telegram → `status: sent`
5. Any step fails → status stays, retry on next poll cycle

Polling loop runs every 2s (configurable).

### Telegram Error Handling

| Error | Handling |
|-------|----------|
| Rate limited (429) | Backoff, retry with delay |
| Message too long | Split into chunks (4096 char limit) |
| Chat not found | Mark chat as inactive |
| Network timeout | Retry up to 3 times |

### OpenCode Session Errors

| Error | Handling |
|-------|----------|
| Session not found | Create new session, update mapping |
| Prompt timeout | Abort session, notify user, retry |
| Model unavailable | Fall back to secondary model |
| Auth expired | Re-authenticate, retry |

### Graceful Shutdown

```
SIGTERM/SIGINT received
  → Stop accepting new Telegram messages
  → Wait for in-flight prompts (up to 30s)
  → Save queue state to SQLite
  → SIGTERM to opencode serve
  → Close SQLite
  → Exit
```

## Testing Strategy

### Unit Tests

Table-driven tests per package:

| Package | Coverage |
|---------|----------|
| `internal/db` | CRUD, migrations, edge cases |
| `internal/telegram` | Message parsing, command detection, response splitting |
| `internal/processor` | Prompt building, status transitions, concurrency |
| `internal/opencode` | Client wrapper (mocked HTTP), session management |
| `internal/skills` | Discovery, frontmatter parsing, trigger matching |

### Integration Tests

Against real SQLite + mock OpenCode server:
- Full message flow: Telegram → DB → OpenCode → response → DB
- Session recovery: session disappears → new session created
- Queue drain: messages queued during downtime → processed on recovery
- Credential priority: env var > credentials.yaml > .env

### Manual Testing Checklist

- [ ] Fresh install: `druzhok` → guided setup
- [ ] Send message → get AI response
- [ ] `/prompt You are a pirate` → pirate-themed responses
- [ ] `/reset` → fresh session
- [ ] `/model openai/gpt-4o` → model switches
- [ ] Kill `opencode serve` → auto-restart, no messages lost
- [ ] Long response → split across Telegram messages
- [ ] Multiple chats → isolated sessions

## Future Evolution (Phase 2+)

### Scheduled Tasks

```sql
CREATE TABLE scheduled_tasks (
    id              TEXT PRIMARY KEY,
    user_id         TEXT NOT NULL REFERENCES users(id),
    chat_id         TEXT NOT NULL REFERENCES chats(id),
    prompt          TEXT NOT NULL,
    schedule_type   TEXT NOT NULL CHECK(schedule_type IN ('cron', 'interval', 'once')),
    schedule_value  TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'active',
    next_run        DATETIME,
    last_run        DATETIME,
    last_result     TEXT,
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);
```

### Multi-Tenant

Each user gets their own `opencode serve` in a Docker container:
```
users/
├── user-123/
│   ├── chats/
│   ├── skills/
│   └── opencode.json
└── user-456/
    └── ...
```

User directories become container volumes.

### Per-Chat Agent Switching

`/agent <name>` command to switch OpenCode agents per chat.

### Additional Channels

Channel abstraction designed for extensibility. Future: WhatsApp, Slack, Discord, Gmail — each as a self-registering module (same pattern as NanoClaw).

### Streaming Responses

Async prompts + SSE event subscription for real-time "typing" effect in Telegram via message editing.

### Credential Management via Telegram

`/config` command for runtime credential changes (with proper security measures).
