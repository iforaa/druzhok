# V4 Orchestrator Design

Druzhok v4 transforms from a monolithic Elixir bot into a **rental platform** where users create AI assistant bots that run inside Docker containers using third-party agent runtimes (ZeroClaw, PicoClaw, or any compatible runtime). The Elixir app becomes a pure control plane: container lifecycle, LLM billing proxy, Telegram token management, and web dashboard.

## Context

### Why

Druzhok v3 is a single-tenant Elixir bot. The new goal is a multi-tenant platform where people **rent** personal AI bots. Open-source agent runtimes (ZeroClaw, PicoClaw) are more feature-rich than our custom PiCore — 94+ tools, 30+ chat channels, skills systems, MCP protocol. Instead of reimplementing all of that, we run those runtimes inside containers and orchestrate them.

### Approach

Copy v3 into v4. Strip the bot runtime (`pi_core` app entirely, plus Telegram/session/streaming code from `druzhok` app). Keep the battle-tested orchestration layer (sandbox/Docker, instance management, settings, dashboard). Add new modules: LLM proxy, billing, token pool, health monitoring.

### Key Decisions

- **Bot runtime agnostic** — orchestrator doesn't care what's inside the container (ZeroClaw, PicoClaw, or custom) as long as it accepts OpenAI-compatible LLM endpoint config and exposes `/health`
- **Token-based billing** — users buy token credits, each LLM call deducts from balance
- **Centralized LLM proxy** — all LLM traffic flows through Elixir proxy for billing, access control, and provider routing
- **Platform controls Telegram tokens** — pre-created bot token pool, allocated on instance creation
- **Docker isolation** — each tenant bot runs in its own Docker container

## Architecture

```
Customer (Telegram) ──► Bot Container (ZeroClaw/PicoClaw)
                              │
                              │ POST /v1/chat/completions
                              ▼
                        Elixir Orchestrator
                        ┌──────────────────────────────────┐
                        │  LlmProxy (:4000/v1/*)           │
                        │    ├── authenticate tenant        │
                        │    ├── check budget               │
                        │    ├── enforce model access        │
                        │    ├── route to real provider      │
                        │    ├── stream response back        │
                        │    ├── count tokens               │
                        │    └── log usage                  │
                        │                                    │
                        │  BotManager                        │
                        │    ├── create/start/stop/restart   │
                        │    ├── configure (env vars)        │
                        │    └── workspace provisioning      │
                        │                                    │
                        │  HealthMonitor                     │
                        │    └── poll /health per instance   │
                        │                                    │
                        │  TokenPool                         │
                        │    └── Telegram bot token mgmt     │
                        │                                    │
                        │  Budget + Usage                    │
                        │    ├── per-tenant balance          │
                        │    └── usage logging               │
                        │                                    │
                        │  Dashboard (LiveView)              │
                        │    ├── instance management         │
                        │    ├── usage/billing UI            │
                        │    └── admin controls              │
                        └──────────────────────────────────┘
                              │
                              │ Real API keys
                              ▼
                        LLM Providers
                        ├── Anthropic (direct)
                        ├── OpenRouter
                        └── Nebius
```

### Network Flow

```
Host machine
├── Elixir app (port 4000)
│     ├── Phoenix web dashboard
│     ├── /v1/* — LLM proxy endpoint
│     └── Finch HTTP client → xray proxy → LLM providers
│
├── Bot container 1 (ZeroClaw, host network)
│     ├── Telegram long-poll (outbound via host network)
│     ├── Gateway :18790 (/health)
│     └── LLM calls → http://host.docker.internal:4000/v1
│
├── Bot container 2 (PicoClaw, host network)
│     └── same pattern
│
└── Bot container N...
```

Bots use `host.docker.internal` (or `172.17.0.1` on Linux) to reach the Elixir proxy on the host. All outbound LLM traffic from bots goes through the proxy. Bots never have real provider API keys.

## What Gets Deleted from V3

### Entire `pi_core` app (~30 files)

- `PiCore.Session`, `Loop`, `Compaction`, `Transform`, `Truncate`
- `PiCore.LLM.*` — Client, OpenAI, Anthropic, SSEParser, Retry, ToolCallAssembler
- `PiCore.Tools.*` — all 13 tools (bash, read, write, edit, grep, find, web_fetch, web_search, memory_write, memory_search, generate_image, set_reminder, cancel_reminder, send_file)
- `PiCore.Memory.*` — Search, Flush, BM25, VectorMath, EmbeddingClient, Chunker, EmbeddingCache
- `PiCore.PromptBudget`, `TokenBudget`, `TokenEstimator`, `Config`, `Multimodal`, `Transcription`
- `PiCore.Native.Readability`
- All PiCore tests and priv/ assets

### From `druzhok` app (~6 files deleted)

- `Agent.Telegram` — bot handles its own Telegram connection
- `Agent.Router` — bot handles message routing
- `Agent.Streamer` — bot handles response streaming
- `Agent.Supervisor` — legacy, unused
- `Agent.ToolStatus` — no tool execution in orchestrator
- `Instance.SessionSup` — no in-process sessions

### From `druzhok` app (~4 files rewritten)

- `Instance.Sup` — rewrite: launch Docker containers instead of GenServer trees
- `InstanceManager` — rewrite: remove PiCore calls, add container lifecycle
- `TokenBudget` — delete (was for PiCore token counting)
- `EmbeddingCache` — delete (was for memory system)

### From `druzhok` app (~4 files removed)

- `ImageDescriber` — bot handles multimodal
- `Reminder` — bot handles scheduling
- `DreamDigest` — was tied to PiCore memory flush
- `LlmRequest` — replaced by LlmProxy

## What Gets Kept

### Data models (minor field additions)

- `Instance` — add: `tenant_key`, `bot_runtime`, `token_balance` fields
- `Model` — as-is (model registry for dashboard display)
- `Settings` — as-is (global key-value config)
- `Pairing` — as-is (device pairing codes)
- `AllowedChat` — as-is (group approval)

### Sandbox layer (no changes)

- `Sandbox` behaviour
- `Sandbox.Docker` / `Sandbox.DockerClient`
- `Sandbox.Firecracker` / `Sandbox.FirecrackerClient`
- `Sandbox.Local`
- `Sandbox.Protocol`

### Supporting modules (no changes)

- `Repo` — SQLite via Ecto
- `Events` — PubSub event system
- `ErrorLogger`, `CrashLog`
- `I18n`

### Web dashboard (adapt)

- Keep LiveView structure
- Update pages for orchestrator concerns

### Config

- `runtime.exs` — keep structure, update env vars (proxy config replaces bot config)

## New Modules

### `Druzhok.BotManager`

Top-level API for bot container lifecycle.

```elixir
defmodule Druzhok.BotManager do
  def create(user_id, opts)      # allocate token, gen tenant key, workspace, docker run
  def start(instance_id)          # docker start
  def stop(instance_id)           # docker stop
  def restart(instance_id)        # docker restart
  def delete(instance_id)         # stop, release token, cleanup workspace
  def configure(instance_id, changes)  # rebuild env vars, restart container
  def status(instance_id)         # running/stopped/unhealthy
end
```

**Create flow:**
1. `TokenPool.allocate()` → Telegram bot token
2. Generate tenant API key → `"dk-bot-{id}-{random}"`
3. Create workspace dir → `/data/tenants/{id}/workspace/`
4. Copy default workspace template (AGENT.md, SOUL.md, etc.)
5. Insert `Instance` record (status: `:starting`)
6. `BotConfig.build(instance)` → env var map
7. `Sandbox.Docker.start(image, env, volumes)`
8. `HealthMonitor.register(instance_id)`
9. Update status: `:running`

### `Druzhok.BotConfig`

Builds env var map for a container based on Instance schema + Settings.

```elixir
defmodule Druzhok.BotConfig do
  def build(instance) do
    base = %{
      "OPENAI_BASE_URL" => "http://host.docker.internal:4000/v1",
      "OPENAI_API_KEY" => instance.tenant_key
    }

    runtime_config = case instance.bot_runtime do
      :zeroclaw -> zeroclaw_env(instance)
      :picoclaw -> picoclaw_env(instance)
      _ -> generic_env(instance)
    end

    Map.merge(base, runtime_config)
  end
end
```

Runtime-specific env vars handle differences in config format between ZeroClaw (TOML-style env) and PicoClaw (JSON-path-style env). Both point LLM requests at the same proxy URL.

### `Druzhok.HealthMonitor`

GenServer polling `/health` on each running container.

- Polls every 30 seconds per instance
- 3 consecutive failures → attempt restart, notify dashboard via PubSub
- Container disappeared → update status to `:crashed`, attempt restart
- Reports health state changes to dashboard in real-time

### `Druzhok.TokenPool`

Manages pre-created Telegram bot tokens.

```elixir
# Ecto schema
schema "tokens" do
  field :token, :string          # "123456:ABC..."
  field :bot_username, :string   # "@druzhok_bot_42"
  belongs_to :instance, Instance # nil = available
  timestamps()
end
```

- `allocate(instance_id)` — claim first available token
- `release(instance_id)` — return token to pool
- Admin UI for adding tokens to the pool

### `Druzhok.LlmProxy`

Phoenix controller mounted at `/v1/*`. OpenAI-compatible API proxy.

**Endpoints:**
- `POST /v1/chat/completions` — main LLM proxy (streaming and non-streaming)
- `GET /v1/models` — list models available to tenant's plan

**Request flow:**
1. Extract tenant key from `Authorization: Bearer dk-bot-...` header
2. Look up Instance by tenant key
3. `Budget.check(instance)` — sufficient balance?
4. `ModelAccess.check(instance, requested_model)` — model allowed on plan?
   - If not allowed: downgrade to best allowed model (e.g., Opus → Sonnet → Haiku)
5. Route to real provider based on model name:
   - `claude-*` → Anthropic (`https://api.anthropic.com/v1/messages`, translate format)
   - `gpt-*`, `deepseek-*`, other OpenRouter models → OpenRouter (`https://openrouter.ai/api/v1/`)
   - Nebius models → Nebius (`https://api.tokenfactory.us-central1.nebius.com/v1/`)
6. Forward request with real API key
7. Stream SSE response back to bot
8. Parse `usage` from final response chunk
9. `Budget.deduct(instance, total_tokens, metadata)`
10. `Usage.log(instance, model, tokens, cost)`

**Format translation:**
- Anthropic uses a different message format than OpenAI. Keep a stripped version of v3's `PiCore.LLM.Anthropic` format translation logic in the proxy.
- OpenRouter and Nebius accept OpenAI format natively — pass through.

**Model access control:**

Bots send real model names (e.g., `claude-sonnet-4-20250514`). The proxy acts as a gatekeeper:

| Bot requests | Free plan | Pro plan | Enterprise |
|---|---|---|---|
| `claude-haiku` | Allow | Allow | Allow |
| `claude-sonnet` | Downgrade → Haiku | Allow | Allow |
| `claude-opus` | Downgrade → Haiku | Downgrade → Sonnet | Allow |
| `deepseek-r1` | Allow | Allow | Allow |

The bot's built-in multi-model routing stays intact. It picks models based on query complexity, and the proxy either forwards as-is or transparently downgrades based on the tenant's plan.

### `Druzhok.Budget`

Per-tenant token accounting.

```elixir
# Ecto schema
schema "budgets" do
  belongs_to :instance, Instance
  field :balance, :integer, default: 0       # tokens remaining
  field :lifetime_used, :integer, default: 0 # total tokens consumed
  timestamps()
end
```

- `check(instance)` → `{:ok, remaining}` or `{:error, :exceeded}`
- `deduct(instance, tokens, metadata)` → subtract from balance
- `add_credits(instance, amount)` → top up (payment or admin grant)

### `Druzhok.Usage`

Logging table for every LLM request.

```elixir
# Ecto schema
schema "usage_logs" do
  belongs_to :instance, Instance
  field :model, :string
  field :prompt_tokens, :integer
  field :completion_tokens, :integer
  field :total_tokens, :integer
  field :cost_cents, :integer          # cost in fractional cents for precision
  field :requested_model, :string      # what bot asked for
  field :resolved_model, :string       # what was actually used (after downgrade)
  field :provider, :string             # anthropic/openrouter/nebius
  field :latency_ms, :integer
  timestamps()
end
```

Query helpers: daily/weekly/monthly aggregation by instance, model, provider.

## Dashboard Updates

### Instance Management Page
- Create bot: name, runtime picker (zeroclaw/picoclaw), initial credits
- Instance list: name, status (running/stopped/unhealthy), runtime, model, balance
- Per-instance: start/stop/restart, configure model, view logs, add credits

### Usage Page
- Per-instance usage table: date, model, tokens, cost
- Charts: daily token consumption, cost breakdown by model
- Global admin view: all tenants, total usage, revenue

### Token Pool Page (admin)
- List all Telegram tokens: token (masked), username, assigned instance
- Add new tokens
- Release orphaned tokens

### Settings Page
- Provider API keys (Anthropic, OpenRouter, Nebius)
- Default model per plan tier
- Token pricing (cost per 1K tokens per model)
- Health check interval

## Database Migrations

### New tables

```sql
CREATE TABLE tokens (
  id INTEGER PRIMARY KEY,
  token TEXT NOT NULL,
  bot_username TEXT,
  instance_id INTEGER REFERENCES instances(id),
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE budgets (
  id INTEGER PRIMARY KEY,
  instance_id INTEGER NOT NULL REFERENCES instances(id),
  balance INTEGER NOT NULL DEFAULT 0,
  lifetime_used INTEGER NOT NULL DEFAULT 0,
  inserted_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE usage_logs (
  id INTEGER PRIMARY KEY,
  instance_id INTEGER NOT NULL REFERENCES instances(id),
  model TEXT NOT NULL,
  prompt_tokens INTEGER NOT NULL,
  completion_tokens INTEGER NOT NULL,
  total_tokens INTEGER NOT NULL,
  cost_cents INTEGER NOT NULL DEFAULT 0,
  requested_model TEXT,
  resolved_model TEXT,
  provider TEXT,
  latency_ms INTEGER,
  inserted_at TEXT NOT NULL
);
```

### Alter existing tables

```sql
ALTER TABLE instances ADD COLUMN tenant_key TEXT;
ALTER TABLE instances ADD COLUMN bot_runtime TEXT DEFAULT 'zeroclaw';
```

## Module Map

```
v4/apps/
├── druzhok/lib/druzhok/
│   ├── application.ex          # App startup (updated)
│   ├── repo.ex                 # SQLite (kept)
│   ├── events.ex               # PubSub (kept)
│   ├── error_logger.ex         # Error tracking (kept)
│   ├── crash_log.ex            # Crash logging (kept)
│   ├── i18n.ex                 # Translations (kept)
│   │
│   ├── instance.ex             # Schema (updated: +tenant_key, +bot_runtime)
│   ├── instance_manager.ex     # Lifecycle API (rewritten)
│   ├── instance/sup.ex         # Per-instance supervisor (rewritten)
│   ├── instance_watcher.ex     # (kept or merged into HealthMonitor)
│   │
│   ├── bot_manager.ex          # NEW — container lifecycle
│   ├── bot_config.ex           # NEW — env var builder
│   ├── health_monitor.ex       # NEW — /health polling
│   ├── token_pool.ex           # NEW — Telegram token management
│   ├── llm_proxy.ex            # NEW — OpenAI-compatible proxy logic
│   ├── budget.ex               # NEW — token balance accounting
│   ├── usage.ex                # NEW — LLM usage logging
│   ├── model_access.ex         # NEW — plan-based model gating
│   │
│   ├── model.ex                # Schema (kept)
│   ├── model_info.ex           # Model metadata (kept)
│   ├── settings.ex             # Key-value config (kept)
│   ├── pairing.ex              # Device pairing (kept)
│   ├── allowed_chat.ex         # Group approval (kept)
│   │
│   ├── sandbox.ex              # Behaviour (kept)
│   ├── sandbox/docker.ex       # Docker wrapper (kept)
│   ├── sandbox/docker_client.ex # Docker GenServer (kept)
│   ├── sandbox/firecracker.ex  # Firecracker wrapper (kept)
│   ├── sandbox/firecracker_client.ex # (kept)
│   ├── sandbox/local.ex        # Local fallback (kept)
│   ├── sandbox/protocol.ex     # TCP JSON-RPC (kept)
│   │
│   └── scheduler.ex            # Rewrite: trigger heartbeats via HTTP to bot
│
├── druzhok_web/lib/druzhok_web/
│   ├── router.ex               # Add /v1/* proxy route
│   ├── controllers/
│   │   └── llm_proxy_controller.ex  # NEW — proxy HTTP handler
│   └── live/
│       ├── dashboard_live.ex   # Updated: instance + billing UI
│       ├── usage_live.ex       # NEW — usage charts
│       └── admin_live.ex       # NEW — token pool, settings
│
└── (pi_core/ — DELETED entirely)
```

## Error Handling

- **Bot container won't start:** Log error, set instance status to `:failed`, show in dashboard. Don't auto-retry indefinitely — cap at 3 attempts.
- **Health check fails:** 3 consecutive failures → restart. 3 restart failures → set `:crashed`, alert admin.
- **LLM proxy — budget exceeded:** Return HTTP 429 with `{"error": {"message": "Token budget exceeded", "type": "insufficient_quota"}}`. Bot handles this as a provider error.
- **LLM proxy — provider down:** Try fallback provider if available (Anthropic down → route claude models through OpenRouter). Return 502 if all providers fail.
- **LLM proxy — streaming interrupted:** Budget deduction based on tokens received so far (from partial usage data or token estimation from streamed text).
- **Telegram token pool empty:** Reject bot creation with clear error in dashboard.

## Testing Strategy

- **BotManager:** Test with mock Docker client (already have sandbox abstraction)
- **LlmProxy:** Test format translation, model routing, budget checks with mock HTTP responses
- **Budget:** Unit tests for deduction, overflow, concurrent deductions
- **HealthMonitor:** Test with mock HTTP endpoints, verify restart logic
- **Integration:** Spin up a real ZeroClaw container in test, verify end-to-end flow (LLM proxy → budget deduction → usage logging)

## Open Questions (resolved during brainstorming)

- **Who holds Telegram tokens?** Platform controls them via TokenPool.
- **How do bots talk to LLM?** Via local proxy (`http://host.docker.internal:4000/v1`), never directly to providers.
- **How to switch models?** Proxy resolves model names per-tenant — no container restart needed.
- **How to preserve bot multi-model routing?** Bots send real model names, proxy gates by plan. Bot's routing logic stays intact.
- **Which sandbox?** Docker for now. Firecracker code kept for future upgrade.

## Out of Scope (for now)

- Payment processing (Stripe, etc.) — admin manually adds credits
- User authentication — single admin user, no multi-user auth yet
- Container log streaming in dashboard
- Auto-scaling (multiple hosts)
- Custom domain per bot
- Workspace file editor in dashboard
