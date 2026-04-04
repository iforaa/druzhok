# OpenClaw Multi-Tenant Pool Design

## Problem

OpenClaw uses ~500 MB RAM per instance. At 1 container per user, 100 users = 50 GB RAM. Not viable on a single server.

## Solution

Pool multiple users into shared OpenClaw containers. 10 users per pool = 100 users in ~7 GB RAM. OpenClaw supports multi-agent routing with per-agent workspace, session, and credential isolation.

## Architecture

```
BotManager.start("alice")
  → Runtime.OpenClaw.pooled?() == true
    → PoolManager.assign(instance)
      → Find pool with capacity (round-robin, fill gaps)
      → Or create new pool container
      → Regenerate openclaw.json for the pool
      → Restart container (new volume mounts)
      → Verify /healthz
      → Return {:ok, pool}
```

```
Druzhok Orchestrator (Elixir, ~300 MB)
  ├── LLM Proxy (/v1/chat/completions)
  ├── PoolManager GenServer
  ├── HealthMonitor
  └── Web Dashboard (Phoenix LiveView)

Pool Container 1 (OpenClaw slim, ~500 MB)
  ├── agent-alice → Telegram bot 1 → sandbox container for exec
  ├── agent-bob   → Telegram bot 2 → sandbox container for exec
  └── ... up to 10 agents

Pool Container 2 (OpenClaw slim, ~500 MB)
  ├── agent-charlie → Telegram bot 3
  └── ...

LLM flow:
  agent → tenant_key auth → Druzhok proxy → 1 OpenRouter key → OpenRouter
```

## Data Model

### New table: pools

| Field | Type | Notes |
|-------|------|-------|
| id | integer PK | auto-increment |
| name | string unique | "openclaw-pool-1" |
| container | string unique | "druzhok-pool-1" |
| port | integer unique | 18800, 18801, ... |
| max_tenants | integer | default 10, set to 1 for premium |
| status | string | "running", "stopped", "starting", "failed" |
| inserted_at | datetime | |
| updated_at | datetime | |

### Instance changes

Add `pool_id` (integer FK, nullable) to instances table.

- `pool_id = nil` → solo runtime (ZeroClaw, PicoClaw, NullClaw)
- `pool_id = N` → this instance lives in pool N
- Premium user = pool with `max_tenants: 1`

## PoolManager GenServer

### API

```elixir
PoolManager.assign(instance)    # → {:ok, pool}
PoolManager.remove(instance)    # → :ok
PoolManager.get_pool(instance)  # → %Pool{} | nil
PoolManager.pools()             # → [%Pool{}]
```

### Lifecycle

**On orchestrator boot:**
1. Load all pools from DB
2. For each pool with status "running", verify Docker container exists
3. If container missing, restart with current config
4. Register with HealthMonitor

**On assign(instance):**
1. Find first pool where `count(instances) < max_tenants`
2. If none found, create new pool (next port, new container)
3. Set `instance.pool_id = pool.id`
4. Stop pool container
5. Regenerate openclaw.json for the pool
6. Recreate container with updated volume mounts
7. Verify `/healthz` (retry up to 10s)
8. Return `{:ok, pool}`

**On remove(instance):**
1. Set `instance.pool_id = nil`
2. If pool has remaining instances → stop, regenerate, recreate, verify
3. If pool is empty → stop container, set status "stopped"

### Supervision

GenServer under Druzhok application supervisor, started after Repo.

## Config Generation

Each pool gets a single `openclaw.json` containing all agents, bindings, and per-tenant providers.

### Structure

```json
{
  "gateway": {
    "bind": "0.0.0.0",
    "port": 18800,
    "reload": { "mode": "hybrid" }
  },
  "session": {
    "dmScope": "per-channel-peer"
  },
  "models": {
    "providers": {
      "tenant-alice": {
        "baseUrl": "http://HOST:4000/v1",
        "apiKey": "dk-alice-xxx",
        "api": "openai-completions",
        "models": [
          { "id": "gpt-4o", "name": "default" },
          { "id": "claude-sonnet-4-20250514", "name": "smart" }
        ]
      },
      "tenant-bob": {
        "baseUrl": "http://HOST:4000/v1",
        "apiKey": "dk-bob-yyy",
        "api": "openai-completions",
        "models": [
          { "id": "gpt-4o", "name": "default" }
        ]
      }
    }
  },
  "agents": {
    "defaults": {
      "sandbox": { "mode": "all" }
    },
    "list": [
      {
        "id": "alice",
        "model": "tenant-alice/gpt-4o",
        "workspace": "/data/workspaces/alice"
      },
      {
        "id": "bob",
        "model": "tenant-bob/gpt-4o",
        "workspace": "/data/workspaces/bob"
      }
    ]
  },
  "channels": {
    "telegram": {
      "accounts": {
        "alice": { "botToken": "111:AAA..." },
        "bob": { "botToken": "222:BBB..." }
      }
    }
  },
  "bindings": [
    { "agentId": "alice", "match": { "channel": "telegram", "accountId": "alice" } },
    { "agentId": "bob", "match": { "channel": "telegram", "accountId": "bob" } }
  ]
}
```

### Key decisions

- **Per-tenant provider**: each agent gets its own provider entry with unique tenant_key. Druzhok LLM proxy meters each user independently.
- **Per-tenant Telegram account**: each agent routes through its own bot token. Account ID = instance name.
- **Sandbox ON by default**: `agents.defaults.sandbox.mode: "all"`. Exec commands run in isolated Docker containers. Users can't access each other's workspaces.
- **`dmScope: per-channel-peer`**: independent sessions per agent + channel + peer.
- **On-demand model**: if instance has `on_demand_model`, a second model ("smart") is added to that tenant's provider. TOOLS.md orchestrator pattern tells the agent how to switch.

## Container Lifecycle

### Docker run command

```bash
docker run -d \
  --name druzhok-pool-1 \
  --network host \
  --restart unless-stopped \
  -v /data/pools/pool-1:/data \
  -v /data/instances/alice/workspace:/data/workspaces/alice \
  -v /data/instances/bob/workspace:/data/workspaces/bob \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e OPENCLAW_CONFIG_PATH=/data/openclaw.json \
  -e OPENCLAW_STATE_DIR=/data/state \
  -e NODE_OPTIONS="--max-old-space-size=512" \
  -e NODE_ENV=production \
  openclaw:slim \
  node openclaw.mjs gateway --allow-unconfigured --bind lan
```

### Membership changes require container restart

Adding or removing a user requires a new `-v` mount. Docker doesn't support adding mounts to running containers. Flow:

1. Stop pool container (`docker rm -f`)
2. Regenerate openclaw.json
3. Recreate container with updated mount list
4. Verify `/healthz`

OpenClaw sessions persist to disk (`state/` directory), so conversations survive restarts. Users see ~5s of "bot not responding".

## File System Layout

```
/data/
├── instances/                    # per-user (unchanged)
│   ├── alice/
│   │   └── workspace/            # AGENTS.md, SOUL.md, MEMORY.md, etc.
│   └── bob/
│       └── workspace/
├── pools/                        # per-pool (new)
│   ├── pool-1/
│   │   ├── openclaw.json         # generated multi-agent config
│   │   ├── state/                # OpenClaw sessions, internal state
│   │   └── sandbox/              # sandbox container data
│   └── pool-2/
│       └── ...
└── druzhok.db                    # SQLite (instances + pools tables)
```

## BotManager Integration

### Runtime behaviour change

Add one callback:

```elixir
@callback pooled?() :: boolean()
# ZeroClaw, PicoClaw, NullClaw → false
# OpenClaw → true
```

### BotManager.start/1

```elixir
if runtime.pooled?() do
  {:ok, pool} = PoolManager.assign(instance)
  start_log_watcher(instance, pool.container)
else
  start_container(instance, runtime)  # existing logic
end
```

### BotManager.stop/1

```elixir
if runtime.pooled?() do
  PoolManager.remove(instance)
else
  stop_container(instance)  # existing logic
end
```

### What stays the same

- BotManager.create/2, delete/1 — unchanged
- Instance schema — unchanged except new pool_id field
- All solo adapters (ZeroClaw, PicoClaw, NullClaw) — unchanged
- LLM proxy — unchanged, authenticates by tenant_key
- Token pool — unchanged

### HealthMonitor

Registers pool containers. If pool fails 3 consecutive checks, restart the pool container. All instances in the pool come back together.

### LogWatcher

One LogWatcher per pool container. Dispatches rejection events by matching agent name in log lines to the correct instance.

## Dashboard Changes

### Left sidebar hierarchy

```
POOLS
  pool-1 (8/10)
    alice
    bob
    charlie
    ...
  pool-2 (3/10)
    dave
    eve
    frank
```

- Click pool → pool-level info (status, RAM, port, tenant count)
- Click instance → instance settings (model, token, workspace, budget, allowed users)

### Instance settings (within pool context)

Same as today: model, on-demand model, Telegram token, allowed users, budget, workspace files, mention-only, timezone, language.

Additional: **Premium toggle** — sets pool `max_tenants: 1`, giving the user a dedicated container on next pool assignment.

### No new pages

Everything in existing dashboard. Sidebar reflects pool → instance hierarchy.

## Resource Estimates

### 100 users, 10 per pool

| Component | Count | RAM each | Total |
|-----------|-------|----------|-------|
| Druzhok orchestrator | 1 | 300 MB | 300 MB |
| OpenClaw pool containers | 10 | 500 MB | 5 GB |
| Docker shim overhead | 10 | 15 MB | 150 MB |
| OS overhead | 1 | 500 MB | 500 MB |
| **Total** | | | **~6 GB** |

### Server requirements

- 8 GB RAM server handles 100 users comfortably
- Each pool: slim image + `--max-old-space-size=512` caps heap at 512 MB
- Sandbox containers are ephemeral (spawned per exec, stopped after)
- One OpenRouter API key, per-user metering via Druzhok proxy

## Security & Isolation

| Layer | Mechanism |
|-------|-----------|
| Session isolation | Per-agent session keys (`agent:{id}:{channel}:{peer}`) |
| Workspace isolation | Individual volume mounts per agent |
| Exec isolation | Sandbox mode ON: exec runs in separate Docker container |
| File tool isolation | OpenClaw scopes read/write to agent's configured workspace |
| Credential isolation | Per-agent provider config, agents don't see each other's keys |
| Budget isolation | Per-tenant LLM proxy auth with individual token limits |
| Blast radius | Max 10 users affected if one pool crashes |

## Error Handling

| Failure | Response |
|---------|----------|
| Pool container won't start | Log error, mark pool "failed", try next pool |
| Health check fails after restart | Retry 3 times (10s total), log error, don't assign |
| Docker daemon unavailable | Return `{:error, :docker_unavailable}` |
| Pool container crashes at runtime | HealthMonitor detects, restarts, config on disk |
| Empty pool after user removal | Stop container, mark pool "stopped" |
