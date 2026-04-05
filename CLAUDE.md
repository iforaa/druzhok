# Druzhok

Personal AI assistant platform. v3 (Elixir/Phoenix) is the legacy single-bot runtime. v4 is the multi-bot orchestrator ("Claw Hub") managing OpenClaw, ZeroClaw, PicoClaw, NullClaw instances.

## Commits

Always use `/my-commit` skill for committing changes. Never use raw git commit commands.

## Critical Rules

### Never wipe workspace
Never run `rm -rf workspace` when restarting the bot. The workspace contains the bot's memory, identity, and conversation history. Only wipe if the user explicitly asks for a fresh start.

### Docker container permissions
Bot containers run as root inside Docker. Files they create in bind-mounted volumes (`/data`) are owned by root on the host. Fix with `sudo chown -R igor:igor /home/igor/druzhok-data/v4-instances/<name>/` when you hit permission denied errors.

### Reasoning models need high max_tokens
Models like GLM-5, Kimi K2.5, DeepSeek-R1 put reasoning in `reasoning_content` and the actual reply in `content`. With low `max_tokens`, ALL tokens go to reasoning and `content` is empty. Set `maxTokens: 16384` minimum.

### OpenClaw pool startup is slow
On the 2-CPU/2GB Yandex Cloud VM, OpenClaw takes ~2.5 minutes to cold-start. Health timeout is 180s. Don't reduce it.

### OpenClaw config quirks
- `gateway.auth.mode: "none"` + `gateway.bind: "loopback"` — these must match; OpenClaw refuses `bind: "lan"` without auth.
- `allowFrom` goes at account level, NOT nested under `"dm"`.
- `sandbox.mode: "all"` — requires Docker CLI in the image (built with `OPENCLAW_INSTALL_DOCKER_CLI=1`).

### NEVER set HTTP_PROXY/HTTPS_PROXY env vars in pool containers
The host's iptables routes all traffic through xray automatically (`--network host`). Setting proxy env vars causes OpenClaw's undici ProxyAgent to corrupt multipart FormData — breaking audio transcription and other file uploads. All outbound traffic from containers already goes through xray without env vars.

## Project Structure

```
v4/
├── druzhok/           # Elixir orchestrator (Claw Hub)
│   ├── apps/druzhok/      # Core: BotManager, PoolManager, Instance, Runtime adapters
│   └── apps/druzhok_web/  # Phoenix dashboard (LiveView)
├── openclaw/          # OpenClaw source (Node.js, used for Docker builds)
├── zeroclaw/          # ZeroClaw (Rust)
├── picoclaw/          # PicoClaw (Go)
├── nullclaw/          # NullClaw (Zig)
└── elixirclaw/        # ElixirClaw (extracted from v3)
```

## v4 Architecture — Pool System

OpenClaw instances are pooled (10 users per container) to reduce RAM from 50GB to ~6GB for 100 users.

```
Druzhok Orchestrator (Elixir, ~300 MB)
  ├── LLM Proxy (/v1/chat/completions) → OpenRouter (1 API key for all)
  ├── PoolManager GenServer (manages pool containers)
  ├── HealthMonitor (30s checks)
  └── Dashboard (Phoenix LiveView, port 4000)

Pool Container (OpenClaw slim, ~500 MB)
  ├── agent-alice → Telegram bot 1
  ├── agent-bob → Telegram bot 2
  └── ... up to 10 agents per pool
```

Key modules:
- `Druzhok.PoolManager` — assigns instances to pools, creates/restarts containers
- `Druzhok.PoolConfig` — generates multi-agent OpenClaw JSON config
- `Druzhok.Pool` — Ecto schema for pools table
- `Druzhok.Runtime` — behaviour with `pooled?/0` callback
- `Druzhok.BotManager` — branches on `pooled?()` for start/stop/restart

Pool data: `/data/pools/pool-name/` (config + state)
Instance workspaces: `/data/instances/name/workspace/` (mounted individually)

Budget: `daily_token_limit: 0` means unlimited (skips budget check).

## Development Commands

```bash
cd v4/druzhok
mix deps.get && mix compile
mix test
DATABASE_PATH=data/druzhok.db mix phx.server   # local dev
DATABASE_PATH=data/druzhok.db mix ecto.migrate  # run migrations
```

## Deploying to Cloud

```bash
# On the server (ssh -l igor 158.160.78.230):
cd ~/druzhok && git pull
source ~/.bashrc; . ~/.asdf/asdf.sh
cd v4/druzhok && mix deps.get && mix compile
DATABASE_PATH=/home/igor/druzhok-data/v4-druzhok.db mix ecto.migrate
sudo systemctl restart druzhok
journalctl -u druzhok -f
```

## Building OpenClaw Docker Image

```bash
# Build locally for linux/amd64:
cd v4/openclaw
docker buildx build --platform linux/amd64 \
  --build-arg OPENCLAW_VARIANT=slim \
  --build-arg "OPENCLAW_EXTENSIONS=telegram openai" \
  --build-arg OPENCLAW_INSTALL_DOCKER_CLI=1 \
  --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=python3 wkhtmltopdf ffmpeg" \
  -t openclaw:latest --load .

# Compress before transfer (3GB → ~1GB, much faster + rsync resume):
docker save openclaw:latest | gzip > /tmp/openclaw.tar.gz
rsync --partial --progress -e ssh /tmp/openclaw.tar.gz igor@158.160.78.230:/tmp/openclaw.tar.gz

# Load on server:
ssh igor@158.160.78.230 "gunzip -c /tmp/openclaw.tar.gz | docker load && rm /tmp/openclaw.tar.gz"
```

**Important build args:**
- `OPENCLAW_EXTENSIONS="telegram openai"` — pre-install extension deps (openai needed for audio transcription)
- `OPENCLAW_INSTALL_DOCKER_CLI=1` — enables sandbox mode
- `OPENCLAW_DOCKER_APT_PACKAGES="python3 wkhtmltopdf ffmpeg"` — system tools for PDF/audio
- `OPENCLAW_VARIANT=slim` — smaller base image (use `default` for full Debian)

## Debugging Remote Errors

```bash
# Check service logs:
ssh -l igor 158.160.78.230 "journalctl -u druzhok --since '5 min ago' --no-pager | grep -i error | tail -20"

# Check pool container logs:
ssh -l igor 158.160.78.230 "docker logs druzhok-pool-1 2>&1 | tail -20"

# Check pool health:
ssh -l igor 158.160.78.230 "curl -s http://127.0.0.1:18800/healthz"

# Check server load:
ssh -l igor 158.160.78.230 "uptime; free -h; docker stats --no-stream"

# Run OpenClaw with --verbose for detailed plugin/audio/media debugging:
# (stop the pool first, run manually, then check output)
docker run --rm --network host ... openclaw:latest node openclaw.mjs gateway --allow-unconfigured --verbose
```
