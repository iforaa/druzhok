# ElixirClaw

Standalone AI agent runtime extracted from Druzhok v3's PiCore. Runs as a Docker container managed by the Druzhok v4 orchestrator.

## Architecture

ElixirClaw wraps PiCore (the agent loop, LLM clients, tools, memory) with an HTTP/WebSocket gateway. No database, no Telegram — just the agent runtime with a network API.

```
HTTP/WS Gateway (Bandit, port 5000)
  ├── POST /chat/:session_id — send message, get response
  ├── GET  /ws/:session_id   — WebSocket streaming
  ├── GET  /health            — health check
  └── POST /telegram          — webhook (future)
        │
  SessionManager (GenServer)
        │
  PiCore.Session (per chat_id)
  ├── Loop (LLM → tool calls → repeat)
  ├── LLM Client (Anthropic + OpenAI compatible)
  ├── Tools (bash, file I/O, memory, web, grep, find)
  ├── Compaction (context window management)
  └── SessionStore (JSONL persistence)
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `WORKSPACE` | Yes | Path to workspace directory (contains AGENTS.md, SOUL.md, memory/) |
| `MODEL` | Yes | Model name (e.g., `x-ai/grok-4.1-fast`) |
| `API_URL` | Yes | LLM API endpoint (OpenAI-compatible) |
| `API_KEY` | Yes | LLM API key |
| `GATEWAY_PORT` | No | HTTP port (default: 5000) |
| `TZ` | No | Timezone (default: UTC) |
| `INSTANCE_NAME` | No | Instance identifier for logging |
| `HTTP_PROXY_URL` | No | HTTP proxy for outbound requests |

## Development

```bash
mix deps.get
mix compile
WORKSPACE=./workspace MODEL=test API_URL=http://localhost:4000/v1 API_KEY=test mix run --no-halt
```

## Docker

```bash
docker build -t elixirclaw:latest .
docker run -d --network host \
  -v /path/to/workspace:/data/workspace \
  -e WORKSPACE=/data/workspace \
  -e MODEL=x-ai/grok-4.1-fast \
  -e API_URL=http://host.docker.internal:4000/v1 \
  -e API_KEY=your-key \
  elixirclaw:latest
```

## PiCore (Agent Runtime)

PiCore is the extracted agent core from Druzhok v3. Key modules:

- `PiCore.Session` — GenServer managing agent lifecycle and message history
- `PiCore.Loop` — Agent loop (LLM call → parse tool calls → execute → repeat)
- `PiCore.LLM.Client` — Provider router (Anthropic Messages API + OpenAI Chat Completions)
- `PiCore.Compaction` — Summarizes old messages when context window fills up
- `PiCore.TokenBudget` — Allocates context window across system prompt, history, tools
- `PiCore.Tools.*` — 13 tools: bash, read, write, edit, find, grep, memory_search, memory_write, web_fetch, web_search, set_reminder, cancel_reminder, generate_image
- `PiCore.Memory.Search` — Hybrid BM25 + vector search over workspace memory files
- `PiCore.SessionStore` — Persists conversations as JSONL in workspace/sessions/

## Workspace Files

| File | Purpose | Loaded when |
|------|---------|-------------|
| `AGENTS.md` | Operating instructions | Every session |
| `SOUL.md` | Personality | Every session |
| `IDENTITY.md` | Bot name, emoji | Every session |
| `USER.md` | User profile | DM only |
| `MEMORY.md` | Long-term memory index | DM only |
| `memory/*.md` | Memory entries | On search |
| `sessions/*.jsonl` | Conversation history | On session load |

## API

### POST /chat/:session_id
Send a message and get a response (synchronous).

```json
// Request
{"message": "Hello"}

// Response
{"response": "Hi! How can I help?"}
```

### WebSocket /ws/:session_id
Streaming chat via WebSocket.

```json
// Client sends
{"type": "message", "content": "Hello"}

// Server sends (streaming)
{"type": "delta", "content": "chunk"}
{"type": "done", "content": "full response"}
{"type": "error", "content": "error message"}
```

### GET /health
Health check. Returns `{"status": "ok"}`.

## Differences from v3

- No Telegram integration (handled by orchestrator)
- No database (all persistence via workspace files)
- No Druzhok dependencies (fully standalone)
- Inline error messages instead of I18n
- Reminders stubbed out (not available in standalone mode)
- Image generation reads API keys from env vars instead of database
