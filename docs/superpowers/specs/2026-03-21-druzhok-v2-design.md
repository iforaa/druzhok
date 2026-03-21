# Druzhok v2 — Design Specification

Rewrite of Druzhok from Go/OpenCode to TypeScript/pi-agent-core. Adopts OpenClaw's proven patterns for memory, streaming, heartbeat, and response filtering. Designed for multi-user deployment where each user gets their own Docker container.

## Context

Druzhok v1 is a Go Telegram bot backed by OpenCode's agent runtime. It works but is limited by OpenCode's HTTP API abstraction — no control over the model loop, no payload-based delivery, no memory system, no heartbeat. OpenClaw (an open-source personal AI assistant) has solved these problems using `@mariozechner/pi-agent-core` embedded directly in TypeScript.

This spec describes a clean-room TypeScript rewrite that imports pi-agent-core as a library and builds Druzhok-specific architecture around it: a two-component system (per-user instance + central LLM proxy), pluggable channel interface, OpenClaw-style memory with pre-compaction flush, heartbeat mechanism, and payload-based reply pipeline.

### Key Decisions

- **TypeScript** — pi-agent-core is a JS library; embedding it natively avoids cross-language friction
- **Clean-room, not fork** — OpenClaw's codebase handles 20+ channels and is ~100k lines; we take the patterns, not the code
- **Two components** — instance (per-user Docker) + proxy (central, holds API keys)
- **OCI containers** — production deployments SHOULD use gVisor (`runsc`) or equivalent hardened runtime for isolation, since agents have exec access
- **Monorepo** — pnpm workspaces, four packages (core, telegram, proxy, shared)

## System Topology

```
┌─────────────────────────────────────────────────┐
│              Druzhok Instance (Docker)           │
│                                                  │
│  Telegram ←→ Channel    Reply       Agent        │
│  Bot API     Interface  Pipeline    Runtime      │
│                  │          │       (pi-agent)    │
│                  └────┬─────┘           │        │
│                       │                 │        │
│              Memory Manager        Tool Registry │
│              (daily logs,          (exec, fs,    │
│               MEMORY.md,           MCP, browser) │
│               vector search)            │        │
│                                         ▼        │
│                                    Proxy Client  │
└─────────────────────────────────────┬────────────┘
                                      │ HTTPS
                                      ▼
┌─────────────────────────────────────────────────┐
│              Druzhok Proxy (central)             │
│                                                  │
│  Auth          Rate Limiter     Provider Router  │
│  (per-instance   (per-user       (Nebius,        │
│   API keys)      token bucket)   Anthropic,      │
│                                  OpenAI)         │
└─────────────────────────────────────────────────┘
```

### Instance Configuration

Environment variables for secrets:
- `DRUZHOK_TELEGRAM_TOKEN` — Telegram bot token
- `DRUZHOK_PROXY_URL` — URL of the central proxy
- `DRUZHOK_PROXY_KEY` — instance API key for proxy auth

Config file (`druzhok.json`) for everything else: memory settings, tool policies, heartbeat interval, model preferences, per-chat system prompts.

### Proxy Configuration

Environment variables:
- `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `NEBIUS_API_KEY` — provider API keys
- `NEBIUS_BASE_URL` — Nebius endpoint (default `https://api.studio.nebius.com/v1/`)
- `DRUZHOK_PROXY_PORT` — listen port (default 8080)
- `DRUZHOK_PROXY_REGISTRY_PATH` — path to instance registry file

## Agent Runtime

### Dependencies

- `@mariozechner/pi-agent-core` — the model loop (streaming, tool call dispatch, session transcript)
- `@mariozechner/pi-coding-agent` — session management, resource loading, tool definitions
- `@mariozechner/pi-ai` — `streamSimple()` for provider streaming

### Session Model

- One session per Telegram chat (mapped by session key, stored as JSONL)
- Session persists full conversation transcript (user messages, assistant messages, tool calls, tool results)
- `/reset` command deletes the session and starts fresh

### Provider Configuration

- All model calls route through the proxy
- Pi-agent-core sees the proxy as a single OpenAI-compatible endpoint
- Model selection per chat (stored in config, changeable via `/model`)
- The proxy handles routing to the actual provider based on model ID prefix — e.g. `nebius/deepseek-r1`, `anthropic/claude-sonnet-4-20250514`

### Tool Registry

Full tool set, since the container IS the sandbox:
- `exec` — shell command execution
- `read` / `write` / `edit` — file operations within the agent workspace
- `memory_search` / `memory_get` — semantic + keyword memory retrieval
- `message` — proactively send a message to the user's Telegram chat
- MCP client — connect to user-configured MCP servers
- `browser` — headless browser (Playwright, optional)

### System Prompt

Built per-run (not static), includes:
- Agent identity/personality (from `AGENTS.md` in workspace)
- Available tools list
- Skills list (metadata only, loaded on demand)
- Memory guidance ("write durable facts to MEMORY.md, daily notes to memory/YYYY-MM-DD.md")
- Current time, runtime metadata
- Per-chat custom instructions (from `druzhok.json` or `/prompt` command)

### Run Lifecycle

```
User message arrives
  → build system prompt
  → assemble context (history + bootstrap files)
  → call pi-agent-core run
    → model generates response
    → if tool_use: execute tool, feed result back, loop
    → if text: accumulate as ReplyPayload
    → stream text deltas to reply pipeline
  → run ends
  → extract final payloads
  → deliver through reply pipeline
```

## Reply Pipeline & Payload Model

### ReplyPayload

```ts
type ReplyPayload = {
  text?: string;
  mediaUrl?: string;
  mediaUrls?: string[];
  isReasoning?: boolean;   // thinking/reasoning block — suppressed by default
  isError?: boolean;        // error messages get special formatting
  isSilent?: boolean;       // NO_REPLY — don't deliver
  replyToId?: number;        // thread reply
  audioAsVoice?: boolean;
};
```

### Filtering Stages

What the pipeline filters out before delivery:

1. **Tool calls and results** — pi-agent-core consumes these internally. Only final assistant text becomes payloads. The user never sees tool-call chains.
2. **`NO_REPLY` token** — model responds with just `NO_REPLY` → entire response suppressed. Used by heartbeat and memory flush turns.
3. **Reasoning blocks** — `isReasoning: true` payloads dropped unless user opts in.
4. **Duplicate suppression** — if the agent used the `message` tool to send text during the run, the same text in the final payload is deduplicated.
5. **Empty responses** — no text + no media = no delivery.

### Pipeline Flow

```
Agent run produces payloads[]
  → strip NO_REPLY / HEARTBEAT_OK tokens
  → filter reasoning blocks
  → deduplicate against message-tool sends
  → deduplicate against already-streamed content
  → apply reply threading
  → deliver to channel interface
```

### Streaming (Draft Lanes)

Two lanes:
- **answer lane** — streams to Telegram via message editing. First delta creates a new message, subsequent deltas edit it. Rate-limited to ~1 edit/second.
- **reasoning lane** — suppressed by default. When enabled, streams to a separate message above the answer.

When the agent makes a tool call mid-response, the current streamed message is "materialized" (finalized), and a new message starts after the tool call completes.

Anti-flicker: if a streaming delta is shorter than the previous one (provider emitting a shorter prefix snapshot), the update is skipped.

Minimum 30 chars before first send (improves push notification UX).

## Memory System

Plain Markdown files on disk with vector search. Adapted from OpenClaw.

### File Layout

```
workspace/
├── MEMORY.md                    # Curated long-term facts (durable)
├── AGENTS.md                    # Agent identity/personality
├── memory/
│   ├── 2026-03-21.md           # Today's daily log (append-only)
│   ├── 2026-03-20.md           # Yesterday's
│   └── ...
└── sessions/
    ├── telegram:dm:123.jsonl
    ├── telegram:group:456.jsonl
    └── telegram:group:456:topic:7.jsonl
```

### Two Memory Layers

- `MEMORY.md` — curated, durable. Decisions, user preferences, reference facts. Model writes here when something should persist long-term.
- `memory/YYYY-MM-DD.md` — daily append-only log. Running notes, context, ephemeral observations. Auto-loaded: today + yesterday at session start.

### Memory Tools

- `memory_search` — semantic search over all memory files. Returns snippets with file path, line range, score.
- `memory_get` — read a specific memory file or line range.

### Vector Search

- Chunks memory files (~400 tokens, 80-token overlap)
- Embeddings via the proxy's `/v1/embeddings` endpoint
- Stored in a local SQLite database per instance
- Hybrid search: BM25 keyword matching + vector similarity, weighted merge (default 0.7 vector / 0.3 text)
- Temporal decay: daily notes fade over time (default half-life 30 days). `MEMORY.md` never decays.
- MMR diversity re-ranking (lambda 0.7) to avoid returning near-duplicate snippets

### Pre-Compaction Memory Flush

When the session approaches the context window limit:

1. Runtime detects token count crossing threshold (`contextWindow - reserve - softThreshold`)
2. Injects a silent agentic turn with system prompt: "Session nearing compaction. Store durable memories now." User prompt: "Write durable facts to MEMORY.md and ephemeral context to memory/YYYY-MM-DD.md; reply with NO_REPLY if nothing to store."
3. Model writes important context to disk
4. Model responds `NO_REPLY` → suppressed, user sees nothing
5. Context compaction runs (summarizes older history)
6. One flush per compaction cycle (tracked in session state)

### Memory Configuration

```json5
{
  memory: {
    search: {
      enabled: true,
      hybridSearch: { vectorWeight: 0.7, textWeight: 0.3 },
      temporalDecay: { enabled: true, halfLifeDays: 30 },
      mmr: { enabled: true, lambda: 0.7 }
    },
    compaction: {
      reserveTokensFloor: 20000,
      memoryFlush: {
        enabled: true,
        softThresholdTokens: 4000
      }
    }
  }
}
```

## Multi-Chat Support

One instance can serve multiple Telegram chats with isolated sessions but shared memory.

### Session Key Routing

Session keys encode the chat context:
- DM: `telegram:dm:<userId>`
- Group: `telegram:group:<chatId>`
- Forum topic: `telegram:group:<chatId>:topic:<threadId>`

Each session key maps to its own session transcript. The agent maintains separate conversation histories per chat.

### Shared vs Per-Chat

- **Shared** — memory files (`MEMORY.md`, `memory/`), agent personality (`AGENTS.md`), tools. The agent "remembers" across chats because memory is shared. When writing chat-specific notes, the agent naturally labels them.
- **Per-chat** — session transcript, system prompt overlay, model selection.

### Per-Chat System Prompt

Configurable in `druzhok.json`:

```json5
{
  chats: {
    "telegram:group:456": {
      systemPrompt: "You are a code review assistant. Be concise and technical.",
      model: "anthropic/claude-sonnet-4-20250514"
    },
    "telegram:dm:123": {
      systemPrompt: "You are a friendly personal assistant.",
      model: "nebius/deepseek-r1"
    }
  }
}
```

Also settable via `/prompt` command per chat.

### Group Context

In groups, recent messages from other participants are collected and prepended to the prompt so the agent can follow the conversation.

## Heartbeat Mechanism

Periodic agentic turns for proactive work.

### Flow

1. Timer fires on configurable interval (default 30 minutes)
2. Runtime checks `HEARTBEAT.md` — if effectively empty (only headers, whitespace, empty checkboxes), skip the API call entirely
3. If non-empty, inject prompt: "Read HEARTBEAT.md if it exists. Follow it strictly. Do not infer or repeat old tasks from prior chats. If nothing needs attention, reply HEARTBEAT_OK."
4. Agent runs a full turn — can read files, search memory, execute tools
5. Response `HEARTBEAT_OK` → suppressed. Actual text → delivered to configured chat.

### HEARTBEAT.md Example

```markdown
# Heartbeat Tasks

- Check ~/projects/myapp for build failures, notify me if tests are red
- Remind me about standup at 14:00 on weekdays
- Summarize any new files in ~/Downloads every 2 hours
```

### Configuration

```json5
{
  heartbeat: {
    enabled: true,
    every: "30m",
    prompt: "...",                    // override default prompt
    deliverTo: "telegram:dm:123456", // where to send proactive messages
    ackMaxChars: 300
  }
}
```

### Guard Rails

- One heartbeat at a time (skip if previous is still running)
- Heartbeat responses over `ackMaxChars` are truncated
- Heartbeats run against a dedicated session (`system:heartbeat`), separate from user conversation sessions. This prevents heartbeat tool calls from polluting chat transcripts.
- `HEARTBEAT_OK` stripping handles edge cases: trailing punctuation, mixed text, uppercase prefix during streaming

## Channel Interface

Telegram as the first implementation of a pluggable interface.

### Contract

```ts
interface Channel {
  // Lifecycle
  start(): Promise<void>;
  stop(): Promise<void>;

  // Inbound — channel calls these on the runtime
  onMessage: (ctx: InboundContext) => Promise<void>;

  // Outbound — runtime calls these to deliver
  sendMessage(chatId: string, payload: ReplyPayload): Promise<DeliveryResult>;
  editMessage(chatId: string, messageId: number, payload: ReplyPayload): Promise<void>;
  deleteMessage(chatId: string, messageId: number): Promise<void>;

  // Streaming
  createDraftStream(chatId: string, opts: DraftStreamOpts): DraftStream;

  // Feedback signals
  sendTyping(chatId: string): Promise<void>;
  setReaction(chatId: string, messageId: number, emoji: string): Promise<void>;
}

interface InboundContext {
  body: string;
  from: string;
  chatId: string;
  chatType: "direct" | "group";
  senderId: string;
  senderName: string;
  messageId: number;
  replyTo?: ReplyContext;
  media?: MediaRef[];
  sessionKey: string;
  timestamp: number;
}

interface DraftStream {
  update(text: string): void;
  materialize(): Promise<number>;
  forceNewMessage(): void;
  stop(): Promise<void>;
  flush(): Promise<void>;
  messageId(): number | undefined;
}
```

### Telegram Implementation

- Long-polling via `grammy`
- `createDraftStream` → message editing with ~1 edit/second rate limit, min 30 chars before first send
- Group context: collects recent messages from other users
- Forum/topic support via `messageThreadId`
- Media handling: downloads photos/voice/documents to workspace
- Markdown → Telegram HTML conversion
- Message chunking for >4096 chars
- Sticker support: vision-describe or cache, feed as text
- Respects Telegram Bot API rate limits (~30 msg/s global, ~20 msg/min per group chat). The delivery layer queues sends when limits are approached.

### Session Key Resolution

- DM: `telegram:dm:<userId>`
- Group: `telegram:group:<chatId>`
- Forum topic: `telegram:group:<chatId>:topic:<threadId>`

## Proxy Server

Central component that holds provider API keys and gates access.

### API Surface

Two OpenAI-compatible endpoints:

```
POST /v1/chat/completions    — proxied to providers
POST /v1/embeddings          — proxied for memory vector search
```

Pi-agent-core treats the proxy as a standard OpenAI-compatible provider.

### Authentication

- Every request requires `Authorization: Bearer <instance-api-key>`
- Proxy validates against instance registry
- Unknown keys → 401

### Instance Registry

```json5
{
  instances: {
    "key_abc123": {
      name: "igor-personal",
      tier: "default",
      enabled: true
    },
    "key_def456": {
      name: "friend-bot",
      tier: "limited",
      enabled: true
    }
  }
}
```

### Rate Limiting

- Token bucket per instance key
- Configurable per tier:
  - `default`: 60 req/min
  - `limited`: 20 req/min
- Returns 429 with `Retry-After` header
- V1 uses request-count-only limiting. Token-based limits deferred — counting tokens requires parsing streaming responses or waiting for the provider's `usage` field at stream end, which adds complexity. Can be added later by accumulating `usage.total_tokens` from completed responses.

### Provider Routing

Model ID prefix determines the provider:
- `anthropic/*` → Anthropic API
- `openai/*` → OpenAI API
- `nebius/*` → Nebius API (OpenAI-compatible)
- No prefix → configurable default

Proxy strips the prefix and forwards with the real API key. Streaming is passed through transparently (SSE in, SSE out).

### Tech Stack

Lightweight Node.js HTTP server (Fastify or plain `http`). Auth + rate limit + proxy passthrough.

## Project Structure

```
druzhok/
├── packages/
│   ├── core/                     # Agent runtime, reply pipeline, memory
│   │   ├── src/
│   │   │   ├── runtime/          # Pi-agent-core wrapper, run lifecycle
│   │   │   ├── memory/           # Memory manager, vector search, flush
│   │   │   ├── reply/            # ReplyPayload, pipeline stages, NO_REPLY
│   │   │   ├── session/          # Session key routing, transcript persistence
│   │   │   ├── heartbeat/        # Heartbeat timer, HEARTBEAT.md loading
│   │   │   ├── tools/            # Tool registry, built-in tool definitions
│   │   │   ├── config/           # druzhok.json loading, env var resolution
│   │   │   └── channel/          # Channel interface definition
│   │   └── package.json
│   ├── telegram/                 # Telegram channel implementation
│   │   ├── src/
│   │   │   ├── bot.ts            # Grammy bot, long-polling, update handling
│   │   │   ├── delivery.ts       # Send/edit/chunk, markdown→HTML
│   │   │   ├── draft-stream.ts   # Streaming message edits
│   │   │   ├── media.ts          # Photo/voice/document download
│   │   │   ├── context.ts        # InboundContext builder, group history
│   │   │   ├── commands.ts       # /start, /stop, /reset, /model, /prompt
│   │   │   └── format.ts         # Markdown to Telegram HTML
│   │   └── package.json
│   ├── proxy/                    # Central LLM proxy server
│   │   ├── src/
│   │   │   ├── server.ts         # HTTP server, route handling
│   │   │   ├── auth.ts           # Instance key validation
│   │   │   ├── rate-limit.ts     # Token bucket per instance
│   │   │   ├── providers.ts      # Provider routing, model ID parsing
│   │   │   └── config.ts         # Registry loading, env vars
│   │   └── package.json
│   └── shared/                   # Shared types, utilities
│       ├── src/
│       │   ├── types.ts          # ReplyPayload, InboundContext, etc.
│       │   └── tokens.ts         # NO_REPLY, HEARTBEAT_OK constants
│       └── package.json
├── docker/
│   ├── Dockerfile.instance       # Per-user instance image
│   └── Dockerfile.proxy          # Proxy server image
├── workspace-template/           # Default workspace for new instances
│   ├── AGENTS.md
│   ├── HEARTBEAT.md
│   └── memory/
├── package.json                  # Monorepo root (pnpm workspaces)
├── pnpm-workspace.yaml
└── tsconfig.json
```

### Dependencies

- `@mariozechner/pi-agent-core` — model loop
- `@mariozechner/pi-coding-agent` — session management, resource loading
- `@mariozechner/pi-ai` — provider streaming
- `grammy` — Telegram bot
- `better-sqlite3` — vector search index, instance registry
- `pnpm` — package manager (monorepo workspaces)
- `vitest` — test runner

### Build & Dev

```bash
pnpm build              # compile all packages
pnpm dev                # watch mode, restart on changes
pnpm test               # vitest across all packages
pnpm docker:instance    # build instance image
pnpm docker:proxy       # build proxy image
```

## Proxy Resilience

### Health Check

The proxy exposes `GET /health` returning 200 when healthy. Instances poll this on startup and periodically (every 30s) to detect proxy outages.

### Instance Behavior When Proxy Is Down

- Agent runs fail with an `isError: true` payload: "I'm temporarily unable to respond — my backend is unavailable. I'll be back shortly."
- In-flight SSE streams are terminated cleanly (the proxy client detects connection drop and surfaces the error)
- Memory search degrades gracefully: `memory_search` returns empty results with a warning, not an error. BM25 keyword search still works locally without embeddings.
- Heartbeat turns are skipped while the proxy is unreachable
- No request queuing — agent runs are synchronous. The user retries by sending another message.

### Proxy Restarts

Streaming SSE connections are not resumable. If the proxy restarts mid-stream, the instance receives a connection error, surfaces a partial response (if any text was streamed) plus an error indicator, and the user can retry.

## Compaction

Context compaction is handled by pi-agent-core's built-in summarization. When the session transcript exceeds the context window:

1. Pre-compaction memory flush runs (see Memory System)
2. Pi-agent-core's `SessionManager` triggers compaction automatically
3. Older messages are summarized into a compact entry
4. Recent messages are preserved intact
5. The summary + recent messages fit within the context budget

This is pi-agent-core's native behavior — Druzhok does not implement its own compaction. The memory flush runs independently: Druzhok monitors the session's token estimate (available from pi-agent-core's usage data after each run). When the estimate crosses the soft threshold, Druzhok injects the flush turn BEFORE the next user-triggered run. This avoids depending on a `beforeCompaction` hook from pi-agent-core — Druzhok owns the flush timing, pi-agent-core owns the compaction itself.

## Memory Indexing

### When Indexing Runs

- **On boot** — full index of all memory files (`MEMORY.md`, `memory/*.md`)
- **On file change** — filesystem watcher (debounced 1.5s) marks the index dirty. Re-indexing runs asynchronously.
- **On search** — if index is stale, sync runs before returning results
- The agent writing to memory files via `write`/`edit` tools triggers the watcher automatically

### Embedding Model

Uses whatever model the proxy's `/v1/embeddings` endpoint supports. Default: `text-embedding-3-small` (OpenAI) or equivalent. Configurable in `druzhok.json` under `memory.search.model`.

### Index Storage

Per-instance SQLite at `workspace/.druzhok/memory.sqlite`. Stores chunk text, embeddings, file path, line range, and a fingerprint (embedding model + chunking params). If the fingerprint changes (model switch), the index is rebuilt automatically.

## Error Handling

### Failed Agent Runs

If pi-agent-core throws mid-run (network error, provider 500, tool crash):

1. The error is caught by the runtime wrapper
2. An `isError: true` payload is created with a user-friendly message (not the raw stack trace)
3. The partial run IS saved to the session transcript (so the model has context if the user retries)
4. The error payload is delivered through the normal reply pipeline
5. Tool errors within a run do NOT abort the run — pi-agent-core feeds the error back to the model as a tool result, and the model decides how to proceed

### Streaming Errors

If a streaming connection drops mid-response:
- Any text already streamed is materialized (finalized) as-is
- An error indicator is appended or sent as a follow-up message
- The session transcript records the partial response

## Graceful Shutdown

On SIGTERM (Docker stop):

1. Stop accepting new Telegram updates (close long-poll)
2. Stop heartbeat timer
3. Wait for in-progress agent runs to complete (timeout: 30s)
4. Flush any pending memory index writes to SQLite
5. Close SQLite connections
6. Exit

If the 30s timeout expires, force-kill remaining runs. Session transcripts are append-only JSONL, so partial writes are safe (worst case: last line is truncated, which `SessionManager` handles on next load).

## Anthropic Provider Compatibility

The Anthropic Messages API is NOT OpenAI-compatible. The proxy handles this with a translation layer:

- **Inbound**: receives OpenAI-format request from the instance, translates to Anthropic format (extract `system` from messages, add `max_tokens` defaulting to the model's maximum output capacity, restructure `content` blocks)
- **Outbound**: receives Anthropic SSE events, translates to OpenAI-format SSE events (`content_block_delta` → `choices[0].delta.content`, etc.)
- **Streaming**: event-by-event remapping, not buffered — latency is preserved

This translation layer lives in `packages/proxy/src/providers/anthropic.ts`. Each non-OpenAI-compatible provider gets its own translator. Nebius and OpenAI need no translation (native OpenAI format).

Alternative: use LiteLLM as the proxy instead of building our own. Decision deferred to implementation — if the translation layer becomes too complex, swap to LiteLLM.

## Skills System

Skills are markdown instruction files that the agent can load on demand. Carried forward from v1 with the same pattern.

### File Format

```markdown
---
name: setup
description: First-time setup guide
triggers:
  - "^/setup$"
  - "help me set up"
---

# Setup Instructions

Step-by-step guide for the agent to follow...
```

### Discovery and Loading

- Skills live in `workspace/skills/<name>/SKILL.md`
- On boot, the runtime scans for skills and builds a metadata index (name, description, triggers)
- The skills list (metadata only) is included in the system prompt so the model knows what's available
- When a user message matches a trigger regex, the full skill body is loaded and prepended to the prompt
- Skills can also be loaded explicitly by the model via file read tools

### Built-in Skills

Carried forward from v1:
- `setup` — guided first-time installation
- `debug` — troubleshoot server and session issues
- `customize` — change chat behavior, system prompt, model

## Observability

### Structured Logging

All components use structured JSON logging (via `pino` or similar):
- Instance: agent runs, tool calls, memory operations, Telegram events
- Proxy: request/response metadata, auth decisions, rate limit events, provider errors

### Request Tracing

The proxy generates a `X-Request-Id` header for each request. Instances log this ID alongside agent run events, enabling correlation between instance logs and proxy logs.

### Config Precedence

Environment variables override `druzhok.json` values. Precedence (highest to lowest):
1. Environment variables
2. `druzhok.json`
3. Built-in defaults

## Shared Memory — Privacy Model

Memory is shared across all chats within an instance. This is intentional: each instance belongs to a single user, and all chats (DMs, groups) are that user's conversations. The agent can recall context from any chat via `memory_search`.

This is the same model OpenClaw uses. If Druzhok ever supports multi-user instances (multiple people sharing one agent), memory isolation per user would be required. That is out of scope for this design.

## Migration from v1

The Go codebase is replaced entirely. Key concepts that carry forward:
- Per-chat sessions (same idea, new session key format)
- SQLite for persistence (now only for vector search index, not message storage)
- System prompt customization per chat (`/prompt` command)
- Admin model (`/model` command)
- Skills as markdown files (same pattern, loaded on demand)
- Telegram commands: `/start`, `/stop`, `/reset`, `/prompt`, `/model`

What's new:
- pi-agent-core replaces OpenCode subprocess
- Payload-based reply pipeline replaces raw string filtering
- Memory system (MEMORY.md + daily logs + vector search)
- Heartbeat mechanism
- Streaming draft lanes with materialization
- Central proxy for API key management
- Docker containerization per user
- TypeScript monorepo replaces single Go binary
