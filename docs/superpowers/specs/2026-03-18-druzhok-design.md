# Druzhok — Design Specification

Personal AI assistant as a product. Telegram bot backed by OpenCode's multi-model agent runtime. Designed for single-user MVP with a clear path to multi-tenant SaaS.

## Context

Inspired by [NanoClaw](https://github.com/qwibitai/nanoclaw) — a personal Claude assistant that runs agents in isolated containers. Druzhok replaces the Claude Agent SDK with [OpenCode](https://opencode.ai), gaining multi-model support (Claude, GPT, Gemini, local models) and a rich programmatic SDK.

### Key Decisions

- **Go** as the language (native to OpenCode, strong for future containerization)
- **Telegram** as the only channel (for now)
- **No containers** for MVP — `opencode serve` runs directly on the host
- **SQLite** for persistence
- **User** as a first-class concept from day one (even with a single user)
- **Per-chat customization** via system prompts (equivalent to NanoClaw's per-group CLAUDE.md)
- **Skills** as markdown instruction files (same pattern as NanoClaw)

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
|  | Channel   |   | Router    | |
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
               (subprocess, :4096)
```

Single Go binary that:
1. Starts `opencode serve` as a managed subprocess
2. Connects via the Go SDK (`opencode-sdk-go`)
3. Runs the Telegram bot
4. Manages SQLite state

## Data Model

```sql
CREATE TABLE users (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    created_at  DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE chats (
    id              TEXT PRIMARY KEY,
    user_id         TEXT NOT NULL REFERENCES users(id),
    tg_chat_id      INTEGER NOT NULL UNIQUE,
    oc_session_id   TEXT,
    name            TEXT NOT NULL DEFAULT '',
    system_prompt   TEXT NOT NULL DEFAULT '',
    agent           TEXT NOT NULL DEFAULT 'default',
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

CREATE TABLE scheduled_tasks (
    id              TEXT PRIMARY KEY,
    user_id         TEXT NOT NULL REFERENCES users(id),
    chat_id         TEXT NOT NULL REFERENCES chats(id),
    prompt          TEXT NOT NULL,
    schedule_type   TEXT NOT NULL CHECK(schedule_type IN ('cron', 'interval', 'once')),
    schedule_value  TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'active'
                    CHECK(status IN ('active', 'paused', 'completed', 'deleted')),
    next_run        DATETIME,
    created_at      DATETIME DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_messages_status ON messages(status);
CREATE INDEX idx_messages_chat ON messages(chat_id, created_at);
CREATE INDEX idx_chats_tg ON chats(tg_chat_id);
CREATE INDEX idx_tasks_next_run ON scheduled_tasks(status, next_run);
```

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
│   │   ├── db.go                # SQLite connection, migrations
│   │   ├── users.go             # User CRUD
│   │   ├── chats.go             # Chat CRUD, session mapping
│   │   ├── messages.go          # Message storage, status transitions
│   │   └── tasks.go             # Scheduled tasks
│   ├── opencode/
│   │   ├── server.go            # Manage opencode serve lifecycle
│   │   ├── client.go            # Go SDK wrapper
│   │   └── events.go            # SSE event stream consumer
│   ├── telegram/
│   │   ├── bot.go               # Telegram bot setup, polling
│   │   ├── handler.go           # Message/command handler
│   │   └── sender.go            # Response delivery, message splitting
│   ├── router/
│   │   └── router.go            # Message routing, prompt building
│   ├── scheduler/
│   │   └── scheduler.go         # Task scheduling engine
│   └── skills/
│       ├── loader.go            # Discover and parse skill markdown
│       └── registry.go          # Skill registry
├── skills/                      # Built-in skill definitions
│   ├── setup/
│   │   └── SKILL.md
│   ├── customize/
│   │   └── SKILL.md
│   ├── debug/
│   │   └── SKILL.md
│   └── status/
│       └── SKILL.md
├── chats/                       # Per-chat customization (runtime)
│   └── {chat-name}/
│       ├── system-prompt.md
│       └── config.json
├── data/
│   └── druzhok.db
├── go.mod
├── go.sum
└── Makefile
```

## OpenCode Integration

### Server Lifecycle

Druzhok manages `opencode serve` as a child process:

1. **Start:** Spawn `opencode serve --port 4096 --hostname 127.0.0.1`
2. **Health:** Poll `GET /global/health` with backoff until ready
3. **Auth:** Set provider API keys via `POST /provider/{id}/oauth/authorize` or `auth.set()`
4. **Monitor:** Health check every 30s, auto-restart on crash (max 3 retries)
5. **Stop:** SIGTERM on shutdown, wait 10s, SIGKILL if needed

### Session Management

Each Telegram chat maps to one OpenCode session:

```
Chat "Family" (tg_chat_id: -100123) → OpenCode session "sess_abc123"
Chat "Work"   (tg_chat_id: -100456) → OpenCode session "sess_def456"
```

New chats get a new session via `client.Session.Create()`. The mapping is stored in `chats.oc_session_id`.

### Per-Chat System Prompt

Each chat has a `system_prompt` (equivalent of NanoClaw's CLAUDE.md). Prepended to every prompt sent to OpenCode:

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

The agent can also modify its own system prompt (by writing to `chats/{name}/system-prompt.md`), enabling it to "remember" things about a chat across sessions.

### Prompt Execution

MVP uses synchronous prompts:

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
│   ├── default.md        # General-purpose assistant
│   ├── coder.md          # Code-focused agent
│   └── casual.md         # Casual conversation
└── config.json           # Provider and model defaults
```

Users switch agents per-chat via `/agent <name>`.

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

### Skill Types

**Built-in skills** (`skills/`):
- `/setup` — guided first-time installation
- `/customize` — change chat behavior, system prompt, model
- `/debug` — troubleshooting (logs, OpenCode health, session state)
- `/status` — show current config, active chats, scheduled tasks

**Per-chat skills** (`chats/{name}/skills/`) — future, for container isolation.

### Skill Invocation

```
User sends "/debug" in Telegram
  → handler.go detects "/" prefix
  → loader.go reads skills/debug/SKILL.md
  → Sends skill content as prompt to OpenCode session
  → Agent follows instructions, responds
  → Response sent back to Telegram
```

Skills with arguments combine skill content + user input:
```
"/customize speak only in Russian"
  → "{skill content}\n\nUser request: speak only in Russian"
```

### Built-in Commands (Not Skills)

Handled directly by Druzhok without OpenCode:

| Command | Action |
|---------|--------|
| `/start` | Register chat, create DB record |
| `/stop` | Pause chat |
| `/agent <name>` | Switch agent for this chat |
| `/model <id>` | Switch model for this chat |
| `/reset` | Clear session, start fresh |
| `/prompt` | Show current system prompt |
| `/prompt <text>` | Set new system prompt |

## Credential Management

### Storage

```
~/.config/druzhok/
├── config.yaml          # Non-secret config
└── credentials.yaml     # Secrets (0600 permissions)
```

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

### Runtime Reconfiguration

Via Telegram (admin only):
```
/config telegram_token <new-token>
/config model <provider/model>
/config provider add openai <key>
```

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
2. Router picks it up → `status: processing`
3. OpenCode responds → `status: completed`, store response
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
| `internal/router` | Prompt building, status transitions |
| `internal/opencode` | Client wrapper (mocked HTTP), session management |
| `internal/scheduler` | Cron parsing, next-run, task lifecycle |
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

## Future Evolution

### Multi-Tenant (Phase 2)

```
users/
├── user-123/
│   ├── chats/
│   ├── skills/
│   └── opencode.json
└── user-456/
    └── ...
```

Each user gets their own `opencode serve` in a Docker container. User directories become container volumes.

### Additional Channels

Channel abstraction designed for extensibility. Future: WhatsApp, Slack, Discord, Gmail — each as a self-registering module (same pattern as NanoClaw).

### Streaming Responses

Async prompts + SSE event subscription for real-time "typing" effect in Telegram via message editing.
