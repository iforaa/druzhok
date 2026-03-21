# Druzhok

Personal AI assistant as a Telegram bot. TypeScript monorepo with pi-agent-core runtime, pluggable channels, OpenClaw-style memory, and a central LLM proxy.

## Commits

Always use `/my-commit` skill for committing changes. Never use raw git commit commands.

## Development Commands

```bash
pnpm build          # compile all packages
pnpm test           # run all tests (vitest)
pnpm test:watch     # watch mode
pnpm dev            # watch mode build
pnpm proxy          # start proxy server
pnpm clean          # remove dist/ dirs
```

## Project Structure

```
packages/
├── shared/          # Types (ReplyPayload, Channel, DraftStream) + token helpers
├── core/            # Agent runtime, memory, reply pipeline, heartbeat, skills
├── telegram/        # Telegram channel (Grammy bot, delivery, streaming)
└── proxy/           # Central LLM proxy (auth, rate limit, provider routing)
docker/              # Dockerfiles for proxy and instance
workspace-template/  # Default workspace for new instances
tests/               # All test files (mirroring package structure)
docs/                # Design specs and implementation plans
```

## Key Files

| Path | Purpose |
|------|---------|
| `packages/core/src/runtime/` | Agent run wrapper, run dispatcher, system prompt builder, session store |
| `packages/core/src/memory/` | Memory files, chunker, BM25, embeddings, hybrid search, flush, watcher |
| `packages/core/src/reply/` | Reply pipeline, filters, lane manager, streaming coordinator |
| `packages/core/src/heartbeat/` | Heartbeat timer and interval parser |
| `packages/core/src/skills/` | Skill loader and registry |
| `packages/telegram/src/` | Bot, context builder, commands, delivery, draft stream, format |
| `packages/proxy/src/` | Fastify server, auth, rate limit, provider routing, Anthropic translation |
| `docs/superpowers/specs/2026-03-21-druzhok-v2-design.md` | Full design specification |

## Telegram Commands

| Command | Description |
|---------|-------------|
| `/start` | Register chat and resume if paused |
| `/stop` | Pause the chat |
| `/reset` | Delete current session and start fresh |
| `/prompt [text]` | Show or set the system prompt |
| `/model <model-id>` | Switch AI model for this chat |

## Configuration

**Environment variables (instance):**

| Variable | Purpose |
|----------|---------|
| `DRUZHOK_TELEGRAM_TOKEN` | Telegram bot token |
| `DRUZHOK_PROXY_URL` | URL of the central proxy |
| `DRUZHOK_PROXY_KEY` | Instance API key for proxy auth |

**Environment variables (proxy):**

| Variable | Purpose |
|----------|---------|
| `ANTHROPIC_API_KEY` | Anthropic API key |
| `OPENAI_API_KEY` | OpenAI API key |
| `NEBIUS_API_KEY` | Nebius API key |
| `NEBIUS_BASE_URL` | Nebius endpoint (default: `https://api.tokenfactory.nebius.com/v1/`) |

**Config file:** `druzhok.json` for non-secret settings (memory, heartbeat, per-chat prompts, model).

See `.env.example` for all variables.
