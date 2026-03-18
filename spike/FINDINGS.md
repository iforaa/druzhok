# OpenCode SDK Spike — Findings

Date: 2026-03-18
OpenCode version: 1.2.27
SDK version: github.com/sst/opencode-sdk-go v0.19.2

## Summary

The spike validated that OpenCode's HTTP API and Go SDK both work as expected. The API surface is clean and well-suited for Druzhok's needs. The main concern is that prompt execution is **asynchronous** — `POST /session/{id}/message` returns immediately, and results must be collected via SSE event stream or by polling.

## Startup

- `opencode serve --port 14096` starts in ~1 second
- Health endpoint: `GET /global/health` returns `{"healthy":true,"version":"1.2.27"}`
- OpenCode looks for `opencode.json` in the working directory (project config)
- Also loads global config from `~/.config/opencode/opencode.json`
- Logs warning if `OPENCODE_SERVER_PASSWORD` is not set (optional, for securing the HTTP server)

## API Endpoints

### Health
```
GET /global/health → {"healthy":true,"version":"1.2.27"}
```

### Session Management
```
POST /session                          → creates a new session
GET  /session                          → lists all sessions
GET  /session/{id}                     → get session details
DELETE /session/{id}                   → delete session
POST /session/{id}/message             → send a prompt (ASYNC — returns immediately)
```

### Session Create Response
```json
{
  "id": "ses_2fe06f01affeDBfZLp26Arxi3a",
  "slug": "gentle-pixel",
  "version": "1.2.27",
  "projectID": "8024d1a...",
  "directory": "/path/to/project",
  "title": "New session - 2026-03-18T17:23:12.997Z",
  "time": { "created": 1773854592997, "updated": 1773854592997 }
}
```

### Prompt Request (POST /session/{id}/message)
```json
{
  "parts": [
    { "type": "text", "text": "Say hello in one sentence." }
  ]
}
```

Optional fields: `agent`, `model`, `system`, `tools`, `noReply`.

### Prompt Response
Returns immediately with the assistant message shell:
```json
{
  "info": {
    "id": "msg_...",
    "role": "assistant",
    "sessionID": "ses_...",
    "providerID": "anthropic",
    "modelID": "claude-sonnet-4-5",
    "cost": 0,
    "mode": "build",
    "tokens": { "input": 0, "output": 0, "reasoning": 0, "cache": { "read": 0, "write": 0 } },
    "time": { "created": ..., "completed": ... },
    "error": null,
    "summary": false
  },
  "parts": [
    { "type": "text", "text": "...", "id": "...", "sessionID": "...", "messageID": "..." }
  ]
}
```

On error, `info.error` contains:
```json
{
  "name": "APIError",
  "data": {
    "statusCode": 401,
    "message": "invalid x-api-key",
    "isRetryable": false
  }
}
```

### Event Stream (SSE)
```
GET /event → text/event-stream
```

Event types observed:
- `server.connected` — emitted on connect
- `session.created`, `session.updated`, `session.deleted`
- `message.updated`, `message.part.updated`, `message.removed`
- `session.idle` — emitted when prompt processing completes
- `session.error` — emitted on errors

### Other Useful Endpoints
```
GET /agent            → list available agents (e.g., "build")
GET /config           → current configuration
GET /config/providers → available providers and models
GET /file             → file tree
GET /find/file        → file search
GET /find             → text search (grep)
```

## Critical Finding: Async Prompt Execution

**The prompt endpoint (`POST /session/{id}/message`) is non-blocking.** It:
1. Creates the user message
2. Creates an empty assistant message shell
3. Returns the shell immediately
4. Processes the LLM call in the background
5. Emits events as parts are generated

**To get the actual response, Druzhok must either:**
- **Option A (recommended):** Listen to the SSE event stream (`GET /event`) and wait for `session.idle` or accumulate `message.part.updated` events
- **Option B:** Poll the session messages endpoint periodically

The SDK's `Prompt()` method also returns immediately — it does NOT block until the LLM finishes.

## Authentication

### Provider API Keys
- OpenCode passes through to upstream providers (Anthropic, OpenAI, etc.)
- Keys are configured in `opencode.json` via `provider.{name}.options.apiKey`
- Supports env var substitution: `"{env:ANTHROPIC_API_KEY}"`
- Supports file-based secrets: `"{file:~/.secrets/key}"`
- Also supports `opencode providers login` for interactive auth

### Server Password
- `OPENCODE_SERVER_PASSWORD` env var secures the HTTP API
- Optional — server warns but works without it
- For Druzhok (localhost only), probably not needed for MVP

## Go SDK Assessment

### Pros
- Clean, well-typed API (generated from OpenAPI spec via Stainless)
- Proper union types for message parts (`TextPart`, `ToolPart`, `ReasoningPart`, etc.)
- SSE streaming support built-in (`client.Event.ListStreaming()`)
- Base URL configurable via `option.WithBaseURL()` or `OPENCODE_BASE_URL` env var
- Automatic retries (2x default)

### Cons
- `Prompt()` returns immediately (non-obvious from the type signature)
- Some endpoints return HTML instead of JSON (e.g., `/session/{id}/messages` — hits the web UI catch-all)
- `SessionListParams` requires a `Directory` field for scoping (multi-project support)
- Response types use pointer returns for lists (`*[]Session` not `[]Session`)

### Verdict: Use the SDK
The SDK is mature and well-typed. Raw HTTP adds no benefit — the SDK handles serialization, error types, and SSE streaming. Use the SDK with a thin wrapper that handles the async pattern.

## Recommended Architecture for Druzhok

```go
// 1. Start opencode serve
cmd := exec.Command(opencodeBin, "serve", "--port", port)
cmd.Start()

// 2. Create SDK client
client := opencode.NewClient(option.WithBaseURL(baseURL))

// 3. Start event listener (long-lived goroutine)
stream := client.Event.ListStreaming(ctx, opencode.EventListParams{})
go func() {
    for stream.Next() {
        evt := stream.Current()
        // Route events to waiting goroutines
    }
}()

// 4. Per-message flow
session, _ := client.Session.New(ctx, opencode.SessionNewParams{})
resp, _ := client.Session.Prompt(ctx, session.ID, opencode.SessionPromptParams{
    Parts: opencode.F([]opencode.SessionPromptParamsPartUnion{
        opencode.TextPartInputParam{
            Type: opencode.F(opencode.TextPartInputTypeText),
            Text: opencode.F("user message here"),
        },
    }),
})
// resp returns immediately — wait for session.idle event via the event stream
```

## Gotchas

1. **Prompt is async** — biggest surprise; response is empty on return
2. **Messages endpoint** (`GET /session/{id}/messages`) may return HTML — use the SDK's `Messages()` method which likely adds proper Accept headers, or use the correct API path
3. **Directory scoping** — API calls need a `directory` query param to scope to the right project; the SDK handles this via params
4. **opencode.json required** — server needs at least a minimal config in the working directory
5. **Two model calls per prompt** — OpenCode fires both a "title" generation (using `small_model`) and the actual prompt (using `model`) simultaneously
6. **Tool permissions** — the default "build" agent has `*` permissions (allow all), which means the LLM can execute shell commands, write files, etc. Druzhok should configure a restricted agent for safety.
7. **Event stream reconnection** — if the SSE connection drops, need to reconnect; the SDK stream doesn't auto-reconnect

## Performance

- Server startup: ~1 second
- Health check: <5ms
- Session creation: <5ms
- Prompt submission: <10ms (just queuing)
- Actual LLM response: depends on provider (not measured due to auth failure)
- Event stream connection: <5ms
