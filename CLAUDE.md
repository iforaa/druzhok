# Druzhok

Personal AI assistant as a Telegram bot. Elixir/Phoenix umbrella app with pi_core agent runtime, Telegram channel, OpenClaw-style memory, per-bot Docker sandboxes, and a web dashboard.

## Commits

Always use `/my-commit` skill for committing changes. Never use raw git commit commands.

## Critical Rules

### Never wipe workspace
Never run `rm -rf workspace` when restarting the bot. The workspace contains the bot's memory, identity, and conversation history. Only wipe if the user explicitly asks for a fresh start.

### Nebius endpoint
Use `https://api.tokenfactory.us-central1.nebius.com/v1/` (us-central1), NOT `api.tokenfactory.nebius.com`. The non-regional endpoint doesn't support tool calling in streaming mode.

### Docker container permissions
Bot containers (ZeroClaw, PicoClaw) run as root inside Docker. Files they create in bind-mounted volumes (`/data`) are owned by root on the host. The Elixir app (running as `igor`) needs to write config files to the same directory before starting a container. Fix with `sudo chown -R igor:igor /home/igor/druzhok-data/v4-instances/<name>/` when you hit permission denied errors.

### Reasoning models need high max_tokens
Models like GLM-5, Kimi K2.5, DeepSeek-R1 put reasoning in `reasoning_content` and the actual reply in `content`. With low `max_tokens`, ALL tokens go to reasoning and `content` is empty. Set `maxTokens: 16384` minimum.

## Development Commands

```bash
cd v3
mix deps.get        # install dependencies
mix compile          # compile all apps
mix test             # run all tests
mix phx.server       # start Phoenix server
```

## Project Structure (v3 — Elixir umbrella)

```
v3/
├── apps/
│   ├── pi_core/           # Agent runtime, LLM clients, tools, memory, sessions
│   ├── druzhok/           # Instance management, Telegram, sandbox, settings, DB
│   └── druzhok_web/       # Phoenix web dashboard, LiveView
├── config/                # Elixir config (runtime.exs has API keys/URLs)
└── services/
    └── sandbox-agent/     # Go binary for per-bot sandboxes (Dockerfile)
workspace-template/        # Default workspace (Russian, OpenClaw file conventions)
Dockerfile                 # Legacy (not used — app runs directly on host)
```

## Architecture

### Network & VPN traffic flow

The Elixir app runs directly on the host (no parent Docker container). xray (vless client) provides VPN tunneling. All outbound HTTP traffic is routed through xray via Finch HTTP proxy configuration.

```
HOST (Yandex Cloud, 158.160.25.25)
├── xray (vless client, 127.0.0.1:10809)
│   └── outbound → VPN server → internet
│
├── Elixir app (systemd service, port 4000)
│   │  HTTP_PROXY_URL=http://127.0.0.1:10809
│   │  DATABASE_PATH=~/druzhok-data/druzhok.db
│   │
│   │  PiCore.Finch (single pool, all HTTP via xray proxy)
│   │    ├── LLM calls (Nebius, Anthropic, OpenRouter) → xray → VPN
│   │    ├── Telegram API → xray → VPN
│   │    ├── web_fetch tool → xray → VPN
│   │    └── embeddings (Voyage AI) → xray → VPN
│   │
│   └── spawns sandbox containers via Docker CLI
│
└── druzhok-{id}-{name} (sandbox, host network)
    ├── No outbound internet access
    ├── Runs bash commands and file I/O only
    ├── Workspace bind-mounted from ~/druzhok-data/instances/*/workspace
    └── Talks to parent via TCP on localhost (shared secret auth)
```

**Key points:**
- `HTTP_PROXY_URL` env var configures Finch to route all HTTP through xray. If unset, Finch connects directly (for local dev).
- The app runs on the host, not in Docker. xray listens on `127.0.0.1:10809`.
- Sandbox containers are Docker-based (host network) and make no outbound requests.
- There is NO separate proxy process. The Elixir app calls LLM providers directly (through xray).

### Request flow

```
User → Telegram → Elixir app (host)
  → PiCore.Finch → xray (127.0.0.1:10809) → VPN → LLM provider
  → Response back through the chain
  → Tool execution → sandbox container (bash/files only)
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

**Env vars (runtime.exs):**
- `NEBIUS_API_KEY`, `NEBIUS_BASE_URL` — Nebius LLM provider
- `ANTHROPIC_API_KEY`, `ANTHROPIC_API_URL` — Anthropic provider
- `OPENROUTER_API_KEY`, `OPENROUTER_API_URL` — OpenRouter provider
- `HTTP_PROXY_URL` — HTTP proxy for all outbound traffic (xray/VPN)
- `DATABASE_PATH` — SQLite DB path (default: `/data/druzhok.db`)
- `SECRET_KEY_BASE`, `PORT`, `PHX_HOST` — Phoenix config

## Deploying to Cloud

```bash
# On the server (ssh -l igor 158.160.25.25):

# 1. Sync code
cd ~/druzhok && git pull

# 2. Compile
cd v3 && mix deps.get && mix compile

# 3. Run migrations (if needed)
DATABASE_PATH=/home/igor/druzhok-data/druzhok.db mix ecto.migrate

# 4. Restart
sudo systemctl restart druzhok

# 5. Check logs
journalctl -u druzhok -f
```
