# Druzhok

Personal AI assistant platform. v4 is the multi-bot orchestrator ("Claw Hub") managing OpenClaw pool containers.

## Commits

Always use `/my-commit` skill for committing changes.

## Critical Rules

- **Never wipe workspace** — contains bot memory/identity. Only wipe if user explicitly asks.
- **Never set HTTP_PROXY/HTTPS_PROXY in pool containers** — host iptables routes through xray automatically. Proxy env vars corrupt multipart FormData (breaks audio/file uploads).
- **OpenClaw cold-start: ~2.5 min** on 2-CPU VM. Health timeout is 180s. Don't reduce.
- **Sandbox containers can steal Telegram polling** — always `docker update --restart no && docker rm -f` to kill them permanently.

## OpenClaw Config Rules

- `gateway.bind: "loopback"` + `auth.mode: "none"` — must match; refuses `bind: "lan"` without auth.
- `allowFrom` at account level, NOT nested under `"dm"`.
- `requireMention` on per-group config, NOT account level.
- Plugins activate via env vars (`OPENAI_API_KEY`, `OPENROUTER_API_KEY`). Pass dummy values to enable without exposing real keys.
- `OPENCLAW_EXTENSIONS="telegram openai"` in Docker build — without `openai`, audio transcription silently fails.

## Proxy Endpoints

All API calls from pool containers route through the Elixir proxy (localhost:4000):

| Endpoint | Auth | Upstream | Notes |
|----------|------|----------|-------|
| `POST /v1/chat/completions` | tenant_key | OpenRouter | Main LLM calls |
| `POST /v1/embeddings` | tenant_key | OpenRouter | Memory search vectors |
| `POST /v1/audio/transcriptions` | none | OpenAI Whisper | Multipart rebuild (Plug.Parsers consumes body) |
| `POST /v1/responses` | none | OpenRouter | Responses API → chat/completions conversion + SSE streaming |

Image model hardcoded to `google/gemini-2.5-flash-lite` in responses proxy. OpenRouter response has leading whitespace — always `String.trim()` before `Jason.decode()`.

## Project Structure

```
v4/druzhok/apps/druzhok/     # Core: BotManager, PoolManager, PoolConfig, PoolObserver
v4/druzhok/apps/druzhok_web/ # Phoenix dashboard + LLM proxy controller
workspace-template/           # OpenClaw workspace templates (AGENTS.md, SOUL.md, etc.)
```

## Development

```bash
cd v4/druzhok
mix deps.get && mix compile && mix test
DATABASE_PATH=data/druzhok.db mix phx.server
```

## Deploying

```bash
ssh -l igor 158.160.78.230
cd ~/druzhok && git pull
source ~/.bashrc; . ~/.asdf/asdf.sh
cd v4/druzhok && mix compile
DATABASE_PATH=/home/igor/druzhok-data/v4-druzhok.db mix ecto.migrate
sudo systemctl restart druzhok
```

## Building Docker Image

```bash
cd v4/openclaw
docker buildx build --platform linux/amd64 \
  --build-arg OPENCLAW_VARIANT=slim \
  --build-arg "OPENCLAW_EXTENSIONS=telegram openai" \
  --build-arg OPENCLAW_INSTALL_DOCKER_CLI=1 \
  --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=python3 wkhtmltopdf ffmpeg" \
  -t openclaw:latest --load .

# Compress + transfer (3GB → ~1GB):
docker save openclaw:latest | gzip > /tmp/openclaw.tar.gz
rsync --partial --progress -e ssh /tmp/openclaw.tar.gz igor@158.160.78.230:/tmp/
ssh igor@158.160.78.230 "gunzip -c /tmp/openclaw.tar.gz | docker load && rm /tmp/openclaw.tar.gz"
```

Also rebuild sandbox image with python3: `echo 'FROM debian:bookworm-slim\nRUN apt-get update && apt-get install -y python3 && rm -rf /var/lib/apt/lists/*' | docker build -t openclaw-sandbox:bookworm-slim -`

## Debugging

```bash
# Service logs:
journalctl -u druzhok --since '5 min ago' | grep -i error | tail -20
# Container logs:
docker logs druzhok-pool-1 2>&1 | tail -20
# Verbose mode (stops pool, runs manually):
docker run --rm --network host ... openclaw:latest node openclaw.mjs gateway --allow-unconfigured --verbose
# Health check:
curl -s http://127.0.0.1:18800/healthz
```
