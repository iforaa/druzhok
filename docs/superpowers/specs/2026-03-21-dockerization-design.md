# Dockerization & Multi-Tenant Orchestration — Design Specification

Multi-tenant system where each user gets their own Druzhok instance running in a Docker container. A Go orchestrator manages container lifecycle. Instances don't hold API keys — all LLM requests go through the proxy which injects the Nebius token.

## System Topology

```
┌─────────────────────────────────────────────────────────┐
│                    Host Machine                         │
│                                                         │
│  ┌──────────────────┐   ┌──────────────────┐           │
│  │   Orchestrator    │   │     Proxy        │           │
│  │   (Go binary)     │   │  (Node.js)       │           │
│  │                   │   │                   │           │
│  │  POST /instances  │   │  /v1/completions  │           │
│  │  GET /instances   │   │  /v1/embeddings   │           │
│  │  DELETE /instances│   │  /health          │           │
│  │                   │   │                   │           │
│  │  Docker Engine ◄──┤   │  Nebius token ◄───┤──── env  │
│  │  API (socket)     │   │  injection        │           │
│  └────────┬──────────┘   └──────────────────┘           │
│           │                        ▲                     │
│           │ create/stop/remove     │ HTTPS               │
│           ▼                        │                     │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐       │
│  │ Instance A   │ │ Instance B   │ │ Instance C   │      │
│  │ (Docker)     │ │ (Docker)     │ │ (Docker)     │      │
│  │              │ │              │ │              │      │
│  │ Telegram bot │ │ Telegram bot │ │ Telegram bot │      │
│  │ pi-agent     │ │ pi-agent     │ │ pi-agent     │      │
│  │ tools        │ │ tools        │ │ tools        │      │
│  │              │ │              │ │              │      │
│  │ /data ◄──────┤ │ /data ◄──────┤ │ /data ◄──────┤     │
│  └──────────────┘ └──────────────┘ └──────────────┘     │
│        ▲                ▲                ▲               │
│        │                │                │               │
│  data/instances/    data/instances/  data/instances/     │
│    alice/              bob/             carol/           │
│    workspace/          workspace/       workspace/      │
└─────────────────────────────────────────────────────────┘
```

## Components

### 1. Orchestrator (Go)

Manages Docker container lifecycle for Druzhok instances.

**API Endpoints:**

| Method | Path | Description |
|--------|------|-------------|
| `POST /instances` | Create a new instance | Body: `{ name, telegramToken, model?, tier? }` |
| `GET /instances` | List all instances | Returns array of instance statuses |
| `GET /instances/:id` | Get instance status | Returns container state, uptime, model |
| `DELETE /instances/:id` | Stop and remove instance | Stops container, keeps data |
| `POST /instances/:id/restart` | Restart instance | Recreates container |
| `PUT /instances/:id/config` | Update instance config | Body: `{ model?, chats? }` |

**Instance Creation Flow:**

1. Receive `POST /instances` with `{ name, telegramToken, model, tier }`
2. Generate instance API key for proxy auth
3. Register key with proxy (`POST /proxy/instances` or write to shared registry file)
4. Create host directory: `data/instances/{id}/workspace/`
5. Copy workspace template if workspace is empty
6. Create `data/instances/{id}/druzhok.json` with model config
7. Start Docker container:
   ```
   docker run -d \
     --name druzhok-{id} \
     -e DRUZHOK_TELEGRAM_TOKEN={telegramToken} \
     -e DRUZHOK_PROXY_URL=http://host.docker.internal:{proxyPort} \
     -e DRUZHOK_PROXY_KEY={instanceKey} \
     -v ./data/instances/{id}:/data \
     druzhok-instance
   ```
8. Return instance ID and status

**Tech Stack:**
- Go 1.25+
- `github.com/docker/docker/client` — Docker Engine API
- `net/http` or `chi` router — REST API
- SQLite — instance registry (name, key, tier, container ID, status)

**File Structure:**
```
services/orchestrator/
├── go.mod
├── go.sum
├── main.go                    # Entry point, HTTP server
├── api/
│   ├── handlers.go            # HTTP handlers
│   └── middleware.go          # Auth middleware
├── docker/
│   └── manager.go             # Docker container lifecycle
├── registry/
│   └── store.go               # SQLite instance registry
└── proxy/
    └── client.go              # Register/unregister keys with proxy
```

### 2. Proxy Updates

The existing proxy needs one addition: a way for the orchestrator to register/unregister instance API keys at runtime.

**Options:**
- **(A)** Shared JSON file — orchestrator writes `instances.json`, proxy watches it
- **(B)** Proxy API endpoint — `POST /admin/instances` to register keys

**(A)** is simpler for MVP — the proxy already reads `instances.json`. The orchestrator just writes to it.

**Proxy config flow:**
1. Orchestrator writes to `data/proxy/instances.json`
2. Proxy watches the file (or reloads on each request for MVP)
3. Instance key → tier mapping is always fresh

### 3. Instance Docker Image

Already exists as `docker/Dockerfile.instance`. Needs minor updates:
- Entry point: `node dist/instance.js` (already configured)
- Workspace: `/data/workspace` (mounted from host)
- Config: `/data/druzhok.json` (mounted from host)
- No API keys inside the container — only `DRUZHOK_PROXY_URL` and `DRUZHOK_PROXY_KEY`

### 4. Data Directory Structure

```
data/
├── proxy/
│   └── instances.json          # Shared registry (proxy reads, orchestrator writes)
├── instances/
│   ├── alice/
│   │   ├── druzhok.json        # Instance config (model, chats, heartbeat)
│   │   └── workspace/
│   │       ├── AGENTS.md
│   │       ├── SOUL.md
│   │       ├── IDENTITY.md
│   │       ├── USER.md
│   │       ├── HEARTBEAT.md
│   │       ├── MEMORY.md
│   │       └── memory/
│   │           └── 2026-03-21.md
│   ├── bob/
│   │   ├── druzhok.json
│   │   └── workspace/
│   └── carol/
│       ├── druzhok.json
│       └── workspace/
```

### 5. Networking

- Proxy listens on host port (e.g., 8080)
- Orchestrator listens on host port (e.g., 9090)
- Instances connect to proxy via `host.docker.internal:8080` (Docker for Mac/Windows) or Docker network
- For production: create a Docker bridge network `druzhok-net`, attach proxy + all instances. Instances reach proxy via service name.

**Docker network setup:**
```bash
docker network create druzhok-net
# Proxy joins the network
# Each instance joins the network
# Instances reach proxy at proxy:8080
```

### 6. Security

- Instances run in containers (isolation)
- No API keys inside containers — proxy holds Nebius token
- Each instance has a unique proxy key — revokable
- Instance containers have no network access except to the proxy (Docker network policy)
- Workspace data is on the host — backups are simple file copies
- gVisor recommended for production (agent has bash access inside container)

## Instance Lifecycle

```
Created → Starting → Running → Stopping → Stopped
                ↑                    │
                └────── Restart ─────┘

Stopped → Removed (container deleted, data kept)
Removed → Purged (data deleted)
```

## API Examples

**Create instance:**
```bash
curl -X POST http://localhost:9090/instances \
  -H "Content-Type: application/json" \
  -d '{
    "name": "alice",
    "telegramToken": "123456:ABC...",
    "model": "nebius/moonshotai/Kimi-K2.5-fast",
    "tier": "default"
  }'

# Response:
{
  "id": "alice",
  "status": "running",
  "proxyKey": "dk_abc123...",
  "createdAt": "2026-03-21T22:00:00Z"
}
```

**List instances:**
```bash
curl http://localhost:9090/instances

# Response:
[
  { "id": "alice", "status": "running", "model": "nebius/moonshotai/Kimi-K2.5-fast", "uptime": "2h30m" },
  { "id": "bob", "status": "stopped", "model": "nebius/Qwen/Qwen3-235B", "uptime": "0s" }
]
```

**Update config (change model):**
```bash
curl -X PUT http://localhost:9090/instances/alice/config \
  -H "Content-Type: application/json" \
  -d '{ "model": "nebius/Qwen/Qwen3-235B-A22B-Instruct-2507" }'

# Triggers container restart with new config
```

**Stop instance:**
```bash
curl -X DELETE http://localhost:9090/instances/alice
```

## Changes to Existing Code

| Action | File | Change |
|--------|------|--------|
| Modify | `docker/Dockerfile.instance` | Mount `/data/druzhok.json` as config |
| Modify | `packages/proxy/src/config.ts` | Watch/reload `instances.json` |
| Create | `services/orchestrator/` | Entire Go service |
| Create | `data/` directory structure | `.gitkeep` files |
| Modify | `docker/docker-compose.example.yml` | Add orchestrator service + network |
