# Druzhok

Personal AI assistant as a Telegram bot. TypeScript monorepo with pi-agent-core runtime, pluggable channels, OpenClaw-style memory, and a central LLM proxy. Go orchestrator for multi-tenant Docker deployment.

## Commits

Always use `/my-commit` skill for committing changes. Never use raw git commit commands.

## Critical Rules

### Never wipe workspace
Never run `rm -rf workspace` when restarting the bot. The workspace contains the bot's memory, identity, and conversation history. Only wipe if the user explicitly asks for a fresh start.

### Docker image rebuilds
After changing TypeScript code, you MUST rebuild the Docker image (`docker build --no-cache`) for containers to pick up changes. For development, mount `dist/` and `packages/` as volumes to skip rebuilds.

### Proxy URL must end with /v1
Pi-agent-core uses the OpenAI SDK which appends `/chat/completions` to the base URL. If proxy URL is `http://proxy:8080`, the model's `baseUrl` must be `http://proxy:8080/v1`. The code in `agent-run.ts` auto-appends `/v1` if missing.

### Reasoning models need high max_tokens
Models like GLM-5, Kimi K2.5, DeepSeek-R1 put reasoning in `reasoning_content` and the actual reply in `content`. With low `max_tokens`, ALL tokens go to reasoning and `content` is empty. Set `maxTokens: 16384` minimum. Also set `reasoning: true` on the model object so pi-ai extracts `reasoning_content`.

### Nebius endpoint
Use `https://api.tokenfactory.us-central1.nebius.com/v1/` (us-central1), NOT `api.tokenfactory.nebius.com`. The non-regional endpoint doesn't support tool calling in streaming mode.

### Proxy must strip encoding headers
When forwarding upstream responses, strip `content-encoding`, `content-length`, `transfer-encoding` headers. Otherwise clients get gzip-encoded bodies they can't decompress.

### Unknown model providers fall through to Nebius
The proxy parses model IDs like `nebius/model-name`. If the prefix isn't a known provider (anthropic, openai, nebius), fall through to the default provider (Nebius) and use the FULL model ID as-is.

### Instance containers get NO API keys
Containers only get `DRUZHOK_PROXY_URL` and `DRUZHOK_PROXY_KEY`. The proxy holds real API keys and injects them when forwarding. Never pass `NEBIUS_API_KEY` to containers.

### Session caching
`AgentSession` is cached per `sessionKey` in memory. If a session was created while the proxy was down, it caches a broken session. `/reset` clears it. If debugging "0 payloads", check if the session was created before the proxy started.

## Development Commands

```bash
pnpm build          # compile all packages
pnpm test           # run all tests (vitest)
pnpm dev            # watch mode build
pnpm proxy          # start proxy server
```

## Running Locally (without Docker)

```bash
source .env
export DRUZHOK_TELEGRAM_TOKEN NEBIUS_API_KEY NEBIUS_BASE_URL
node dist/instance.js
```

## Running with Docker

```bash
# 1. Start proxy (holds API keys)
source .env && export NEBIUS_API_KEY NEBIUS_BASE_URL
DRUZHOK_PROXY_PORT=8080 DRUZHOK_PROXY_REGISTRY_PATH=./services/orchestrator/data/proxy/instances.json node packages/proxy/dist/index.js

# 2. Start orchestrator
cd services/orchestrator
DOCKER_HOST=unix://$HOME/.docker/run/docker.sock ./orchestrator

# 3. Create instance via API
curl -X POST http://localhost:9090/instances -H "Content-Type: application/json" \
  -d '{"name":"mybot","telegramToken":"BOT_TOKEN","model":"nebius/zai-org/GLM-5"}'

# 4. Dashboard at http://localhost:9090
```

## Project Structure

```
packages/
├── shared/              # Types + token helpers
├── core/                # Agent runtime, memory, reply pipeline, heartbeat, skills
├── telegram/            # Telegram channel (Grammy bot, delivery, streaming)
└── proxy/               # Central LLM proxy (auth, rate limit, provider routing)
services/orchestrator/   # Go orchestrator for multi-tenant Docker management
docker/                  # Dockerfiles
workspace-template/      # Default workspace (Russian, OpenClaw file conventions)
src/instance.ts          # Entry point that wires everything
```

## Architecture

```
User → Telegram → Docker container (no API keys)
  → Proxy (validates dk_ key, adds Nebius token)
  → Nebius API
  → Response back through the chain
```

## Workspace Files (OpenClaw Convention)

| File | Purpose | Loaded when |
|------|---------|-------------|
| `AGENTS.md` | Operating instructions | Every session |
| `SOUL.md` | Personality | Every session |
| `IDENTITY.md` | Bot name, emoji | Every session |
| `USER.md` | User profile | DM only (never in groups) |
| `BOOTSTRAP.md` | First-run instructions | First run, then deleted |
| `HEARTBEAT.md` | Periodic tasks | On heartbeat tick |
| `MEMORY.md` | Long-term memory | DM only |

## Configuration

**Instance env vars:** `DRUZHOK_TELEGRAM_TOKEN`, `DRUZHOK_PROXY_URL`, `DRUZHOK_PROXY_KEY`, `DRUZHOK_CONFIG_PATH`, `DRUZHOK_WORKSPACE_DIR`

**Proxy env vars:** `NEBIUS_API_KEY`, `NEBIUS_BASE_URL`, `DRUZHOK_PROXY_PORT`, `DRUZHOK_PROXY_REGISTRY_PATH`

**Config file:** `druzhok.json` — model, heartbeat, per-chat prompts. Inside Docker: `/data/druzhok.json`
