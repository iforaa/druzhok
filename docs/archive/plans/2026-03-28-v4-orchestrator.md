# V4 Orchestrator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transform Druzhok from a monolithic Elixir bot into a multi-tenant orchestrator that runs ZeroClaw/PicoClaw bots inside Docker containers, with a centralized LLM billing proxy.

**Architecture:** Copy v3 into v4/druzhok, delete pi_core and bot-specific modules, add BotManager (container lifecycle), LlmProxy (OpenAI-compatible billing proxy), TokenPool (Telegram token management), HealthMonitor, and Budget/Usage tracking. The Elixir app becomes a pure control plane.

**Tech Stack:** Elixir/Phoenix umbrella, Ecto/SQLite, Phoenix LiveView, Finch HTTP client, Docker CLI

---

## File Structure

### Files to delete

```
v4/druzhok/apps/pi_core/                          # entire app
v4/druzhok/apps/druzhok/lib/druzhok/agent/telegram.ex
v4/druzhok/apps/druzhok/lib/druzhok/agent/router.ex
v4/druzhok/apps/druzhok/lib/druzhok/agent/streamer.ex
v4/druzhok/apps/druzhok/lib/druzhok/agent/supervisor.ex
v4/druzhok/apps/druzhok/lib/druzhok/agent/tool_status.ex
v4/druzhok/apps/druzhok/lib/druzhok/instance/session_sup.ex
v4/druzhok/apps/druzhok/lib/druzhok/dream_digest.ex
v4/druzhok/apps/druzhok/lib/druzhok/image_describer.ex
v4/druzhok/apps/druzhok/lib/druzhok/reminder.ex
v4/druzhok/apps/druzhok/lib/druzhok/llm_request.ex
v4/druzhok/apps/druzhok/lib/druzhok/tool_execution.ex
v4/druzhok/apps/druzhok/lib/druzhok/token_budget.ex
v4/druzhok/apps/druzhok/lib/druzhok/embedding_cache.ex
v4/druzhok/apps/druzhok/lib/druzhok/prompt_guard.ex
```

### Files to create

```
v4/druzhok/apps/druzhok/lib/druzhok/bot_manager.ex        # container lifecycle
v4/druzhok/apps/druzhok/lib/druzhok/bot_config.ex          # env var builder
v4/druzhok/apps/druzhok/lib/druzhok/health_monitor.ex      # /health polling
v4/druzhok/apps/druzhok/lib/druzhok/token_pool.ex          # Telegram token schema + allocation
v4/druzhok/apps/druzhok/lib/druzhok/budget.ex              # per-tenant token balance
v4/druzhok/apps/druzhok/lib/druzhok/usage.ex               # LLM request logging
v4/druzhok/apps/druzhok/lib/druzhok/model_access.ex        # plan-based model gating
v4/druzhok/apps/druzhok/priv/repo/migrations/20260328000001_v4_add_orchestrator_tables.exs
v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex
v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/plugs/llm_auth.ex
v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/llm_format.ex
```

### Files to rewrite

```
v4/druzhok/apps/druzhok/lib/druzhok/instance.ex            # add tenant_key, bot_runtime fields
v4/druzhok/apps/druzhok/lib/druzhok/instance_manager.ex    # container lifecycle instead of GenServer
v4/druzhok/apps/druzhok/lib/druzhok/instance/sup.ex        # launch Docker container
v4/druzhok/apps/druzhok/lib/druzhok/application.ex         # updated supervision tree
v4/druzhok/apps/druzhok/lib/druzhok/scheduler.ex           # HTTP-based heartbeat triggers
v4/druzhok/apps/druzhok/mix.exs                            # remove pi_core dep
v4/druzhok/config/config.exs                               # remove pi_core config
v4/druzhok/config/runtime.exs                              # LLM provider keys as proxy config
v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/router.ex  # add /v1/* proxy route
```

---

### Task 1: Copy V3 and Strip Pi_Core

**Files:**
- Copy: `v3/` → `v4/druzhok/`
- Delete: `v4/druzhok/apps/pi_core/` (entire directory)
- Modify: `v4/druzhok/apps/druzhok/mix.exs`
- Modify: `v4/druzhok/config/config.exs`
- Modify: `v4/druzhok/config/runtime.exs`

- [ ] **Step 1: Copy v3 to v4/druzhok**

```bash
cp -r v3 v4/druzhok
```

- [ ] **Step 2: Delete pi_core app**

```bash
rm -rf v4/druzhok/apps/pi_core
```

- [ ] **Step 3: Remove pi_core dependency from druzhok mix.exs**

In `v4/druzhok/apps/druzhok/mix.exs`, remove line 29:

```elixir
# REMOVE this line:
{:pi_core, in_umbrella: true},
```

Add finch dependency (was transitive via pi_core, now needed directly for LLM proxy):

```elixir
defp deps do
  [
    {:jason, "~> 1.4"},
    {:phoenix_pubsub, "~> 2.1"},
    {:ecto_sql, "~> 3.12"},
    {:ecto_sqlite3, "~> 0.17"},
    {:finch, "~> 0.18"},
  ]
end
```

- [ ] **Step 4: Remove pi_core config from config.exs**

In `v4/druzhok/config/config.exs`, remove lines 64-65:

```elixir
# REMOVE:
config :pi_core,
  default_api_url: "https://api.tokenfactory.us-central1.nebius.com/v1"
```

- [ ] **Step 5: Replace pi_core runtime config with proxy config**

In `v4/druzhok/config/runtime.exs`, replace lines 86-95 with:

```elixir
# LLM provider credentials (used by the LLM proxy, not by bots)
config :druzhok,
  nebius_api_key: System.get_env("NEBIUS_API_KEY"),
  nebius_api_url:
    System.get_env("NEBIUS_BASE_URL") || "https://api.tokenfactory.us-central1.nebius.com/v1",
  anthropic_api_key: System.get_env("ANTHROPIC_API_KEY"),
  anthropic_api_url: System.get_env("ANTHROPIC_API_URL") || "https://api.anthropic.com",
  openrouter_api_key: System.get_env("OPENROUTER_API_KEY"),
  openrouter_api_url: System.get_env("OPENROUTER_API_URL") || "https://openrouter.ai/api/v1",
  http_proxy_url: System.get_env("HTTP_PROXY_URL")
```

- [ ] **Step 6: Verify it compiles (expect errors from deleted modules)**

```bash
cd v4/druzhok && mix deps.get && mix compile 2>&1 | head -50
```

Expected: Compilation errors referencing PiCore, Agent.Telegram, etc. This is correct — we'll fix them in the next tasks.

- [ ] **Step 7: Commit**

```
feat: copy v3 to v4, remove pi_core app
```

---

### Task 2: Delete Bot-Specific Modules

**Files:**
- Delete: 15 files (see list above)
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/instance/sup.ex` (stub)
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/instance_manager.ex` (stub)
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/application.ex` (stub)

- [ ] **Step 1: Delete bot-specific files**

```bash
cd v4/druzhok/apps/druzhok/lib/druzhok
rm -f agent/telegram.ex agent/router.ex agent/streamer.ex agent/supervisor.ex agent/tool_status.ex
rm -f instance/session_sup.ex
rm -f dream_digest.ex image_describer.ex reminder.ex
rm -f llm_request.ex tool_execution.ex token_budget.ex embedding_cache.ex prompt_guard.ex
rmdir agent 2>/dev/null || true
```

- [ ] **Step 2: Delete Telegram-specific modules if not needed by orchestrator**

Keep `telegram/api.ex` and `telegram/format.ex` — they may still be useful for admin notifications. Delete only if they depend on PiCore (check first).

- [ ] **Step 3: Stub Instance.Sup to remove PiCore references**

Replace `v4/druzhok/apps/druzhok/lib/druzhok/instance/sup.ex` entirely:

```elixir
defmodule Druzhok.Instance.Sup do
  @moduledoc """
  Per-instance supervisor. Manages Docker container + health monitoring.
  Rewritten for v4 orchestrator — no more in-process bot sessions.
  """
  use Supervisor

  def child_spec(config) do
    %{
      id: {__MODULE__, config.name},
      start: {__MODULE__, :start_link, [config]},
      restart: :temporary,
      type: :supervisor,
    }
  end

  def start_link(config) do
    name = {:via, Registry, {Druzhok.Registry, {config.name, :sup}}}
    Supervisor.start_link(__MODULE__, config, name: name)
  end

  def init(config) do
    name = config.name

    sandbox_children = case config[:sandbox] do
      "docker" ->
        [{Druzhok.Sandbox.DockerClient, %{
          instance_name: name,
          workspace: config.workspace,
          registry_name: {:via, Registry, {Druzhok.Registry, {name, :sandbox}}},
        }}]
      "firecracker" ->
        [{Druzhok.Sandbox.FirecrackerClient, %{
          instance_name: name,
          registry_name: {:via, Registry, {Druzhok.Registry, {name, :sandbox}}},
        }}]
      _ -> []
    end

    children = [
      {Druzhok.Scheduler, %{
        instance_name: name,
        workspace: config.workspace,
        heartbeat_interval: config.heartbeat_interval,
        registry_name: {:via, Registry, {Druzhok.Registry, {name, :scheduler}}},
      }},
    ] ++ sandbox_children

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 60)
  end
end
```

- [ ] **Step 4: Stub InstanceManager to remove PiCore references**

Replace `v4/druzhok/apps/druzhok/lib/druzhok/instance_manager.ex` entirely:

```elixir
defmodule Druzhok.InstanceManager do
  @moduledoc """
  Creates and manages bot instances running in Docker containers.
  V4 orchestrator — no in-process bot sessions.
  """

  alias Druzhok.{Instance, Repo}

  def create(name, opts) do
    config = %{
      name: name,
      workspace: opts.workspace,
      model: opts.model,
      heartbeat_interval: opts[:heartbeat_interval] || 0,
      sandbox: opts[:sandbox] || "docker",
      bot_runtime: opts[:bot_runtime] || "zeroclaw",
      tenant_key: opts[:tenant_key] || generate_tenant_key(name),
      telegram_token: opts[:telegram_token],
    }

    ensure_workspace(config.workspace)
    save_to_db(name, config)
    {:ok, %{name: name, model: config.model}}
  end

  def stop(name) when is_binary(name) do
    case Repo.get_by(Instance, name: name) do
      nil -> :ok
      inst -> Repo.update(Instance.changeset(inst, %{active: false}))
    end
    :ok
  end

  def list do
    import Ecto.Query
    Repo.all(from i in Instance, where: i.active == true)
    |> Enum.map(fn inst ->
      %{
        name: inst.name,
        model: inst.model,
        sandbox: inst.sandbox || "docker",
        bot_runtime: inst.bot_runtime || "zeroclaw",
        active: inst.active,
        tenant_key: inst.tenant_key,
      }
    end)
  end

  def delete(name) do
    stop(name)
    case Repo.get_by(Instance, name: name) do
      nil -> :ok
      inst -> Repo.delete(inst)
    end
  end

  defp generate_tenant_key(name) do
    random = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    "dk-#{name}-#{random}"
  end

  defp save_to_db(name, config) do
    case Repo.get_by(Instance, name: name) do
      nil ->
        %Instance{}
        |> Instance.changeset(%{
          name: name,
          telegram_token: config.telegram_token,
          model: config.model,
          workspace: config.workspace,
          sandbox: config.sandbox,
          bot_runtime: config.bot_runtime,
          tenant_key: config.tenant_key,
          active: true,
        })
        |> Repo.insert()

      existing ->
        existing
        |> Instance.changeset(%{
          model: config.model,
          active: true,
        })
        |> Repo.update()
    end
  end

  defp ensure_workspace(workspace) do
    unless File.exists?(workspace) do
      File.mkdir_p!(Path.dirname(workspace))
      template = find_workspace_template()
      if template do
        File.cp_r!(template, workspace)
      else
        File.mkdir_p!(workspace)
        File.mkdir_p!(Path.join(workspace, "memory"))
      end
    end
  end

  defp find_workspace_template do
    candidates = [
      System.get_env("WORKSPACE_TEMPLATE_PATH"),
      Path.join(File.cwd!(), "workspace-template"),
      Path.join([File.cwd!(), "..", "workspace-template"]) |> Path.expand()
    ]

    Enum.find(candidates, fn
      nil -> false
      path -> File.exists?(path)
    end)
  end
end
```

- [ ] **Step 5: Clean up Application to remove PiCore references**

Replace `v4/druzhok/apps/druzhok/lib/druzhok/application.ex`:

```elixir
defmodule Druzhok.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      Druzhok.Repo,
      {Registry, keys: :unique, name: Druzhok.Registry},
      {DynamicSupervisor, name: Druzhok.InstanceDynSup, strategy: :one_for_one},
      {Finch, name: Druzhok.Finch, pools: finch_pools()},
    ]

    opts = [strategy: :one_for_one, name: Druzhok.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp finch_pools do
    case Application.get_env(:druzhok, :http_proxy_url) do
      nil -> %{}
      proxy_url ->
        uri = URI.parse(proxy_url)
        %{default: [conn_opts: [proxy: {String.to_atom(uri.scheme), uri.host, uri.port, []}]]}
    end
  end
end
```

- [ ] **Step 6: Fix Scheduler to remove PiCore session calls**

Read `v4/druzhok/apps/druzhok/lib/druzhok/scheduler.ex` and remove any `PiCore.Session.*` calls. Replace with stubs (we'll implement HTTP-based triggers in a later task). For now, just remove the calls so it compiles:

Any line like `PiCore.Session.prompt_heartbeat(pid, prompt)` → replace with `Logger.info("TODO: heartbeat via HTTP")`.

- [ ] **Step 7: Fix any remaining compilation errors**

```bash
cd v4/druzhok && mix compile 2>&1
```

Fix any remaining references to deleted modules. Common fixes:
- Remove `InstanceWatcher` references to `Agent.Telegram`
- Remove `Events` references to tool execution
- Remove dashboard LiveView references to deleted modules (comment out for now)

- [ ] **Step 8: Verify clean compilation**

```bash
cd v4/druzhok && mix compile 2>&1
```

Expected: 0 errors, possibly warnings about unused variables.

- [ ] **Step 9: Commit**

```
feat: strip bot-specific modules, stub orchestrator
```

---

### Task 3: Database Migration for V4 Fields

**Files:**
- Create: `v4/druzhok/apps/druzhok/priv/repo/migrations/20260328000001_v4_add_orchestrator_tables.exs`
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/instance.ex`

- [ ] **Step 1: Write the migration**

Create `v4/druzhok/apps/druzhok/priv/repo/migrations/20260328000001_v4_add_orchestrator_tables.exs`:

```elixir
defmodule Druzhok.Repo.Migrations.V4AddOrchestratorTables do
  use Ecto.Migration

  def change do
    # Add orchestrator fields to instances
    alter table(:instances) do
      add :tenant_key, :string
      add :bot_runtime, :string, default: "zeroclaw"
    end

    create unique_index(:instances, [:tenant_key])

    # Telegram bot token pool
    create table(:tokens) do
      add :token, :string, null: false
      add :bot_username, :string
      add :instance_id, references(:instances, on_delete: :nilify_all)
      timestamps()
    end

    create unique_index(:tokens, [:token])
    create index(:tokens, [:instance_id])

    # Per-instance token budget
    create table(:budgets) do
      add :instance_id, references(:instances, on_delete: :delete_all), null: false
      add :balance, :integer, null: false, default: 0
      add :lifetime_used, :integer, null: false, default: 0
      timestamps()
    end

    create unique_index(:budgets, [:instance_id])

    # LLM usage log
    create table(:usage_logs) do
      add :instance_id, references(:instances, on_delete: :delete_all), null: false
      add :model, :string, null: false
      add :prompt_tokens, :integer, null: false
      add :completion_tokens, :integer, null: false
      add :total_tokens, :integer, null: false
      add :cost_cents, :integer, null: false, default: 0
      add :requested_model, :string
      add :resolved_model, :string
      add :provider, :string
      add :latency_ms, :integer
      timestamps(updated_at: false)
    end

    create index(:usage_logs, [:instance_id])
    create index(:usage_logs, [:inserted_at])
  end
end
```

- [ ] **Step 2: Update Instance schema**

Replace `v4/druzhok/apps/druzhok/lib/druzhok/instance.ex`:

```elixir
defmodule Druzhok.Instance do
  use Ecto.Schema
  import Ecto.Changeset

  schema "instances" do
    field :name, :string
    field :telegram_token, :string
    field :model, :string
    field :workspace, :string
    field :active, :boolean, default: false
    field :sandbox, :string, default: "docker"
    field :heartbeat_interval, :integer, default: 0
    field :timezone, :string, default: "UTC"
    field :language, :string, default: "ru"
    field :api_key, :string
    field :daily_token_limit, :integer, default: 0
    field :dream_hour, :integer, default: -1
    field :owner_telegram_id, :integer

    # V4 orchestrator fields
    field :tenant_key, :string
    field :bot_runtime, :string, default: "zeroclaw"

    has_one :budget, Druzhok.Budget
    timestamps()
  end

  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [:name, :telegram_token, :model, :workspace, :active,
                    :sandbox, :heartbeat_interval, :timezone, :language,
                    :api_key, :daily_token_limit, :dream_hour, :owner_telegram_id,
                    :tenant_key, :bot_runtime])
    |> validate_required([:name])
    |> unique_constraint(:name)
    |> unique_constraint(:tenant_key)
  end
end
```

- [ ] **Step 3: Run migration**

```bash
cd v4/druzhok && mix ecto.migrate
```

Expected: Migration runs successfully.

- [ ] **Step 4: Commit**

```
feat: add v4 orchestrator database tables
```

---

### Task 4: Token Pool and Budget Schemas

**Files:**
- Create: `v4/druzhok/apps/druzhok/lib/druzhok/token_pool.ex`
- Create: `v4/druzhok/apps/druzhok/lib/druzhok/budget.ex`
- Create: `v4/druzhok/apps/druzhok/lib/druzhok/usage.ex`

- [ ] **Step 1: Write TokenPool test**

Create `v4/druzhok/apps/druzhok/test/druzhok/token_pool_test.exs`:

```elixir
defmodule Druzhok.TokenPoolTest do
  use ExUnit.Case
  alias Druzhok.{TokenPool, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
  end

  test "allocate returns a token and marks it assigned" do
    Repo.insert!(%TokenPool{token: "123:ABC", bot_username: "@test_bot"})
    assert {:ok, token} = TokenPool.allocate(1)
    assert token.token == "123:ABC"
    assert token.instance_id == 1
  end

  test "allocate returns error when pool is empty" do
    assert {:error, :no_tokens_available} = TokenPool.allocate(1)
  end

  test "release returns token to pool" do
    Repo.insert!(%TokenPool{token: "123:ABC", instance_id: 1})
    assert :ok = TokenPool.release(1)
    token = Repo.get_by(TokenPool, token: "123:ABC")
    assert token.instance_id == nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd v4/druzhok && mix test apps/druzhok/test/druzhok/token_pool_test.exs
```

Expected: FAIL — module not defined.

- [ ] **Step 3: Implement TokenPool**

Create `v4/druzhok/apps/druzhok/lib/druzhok/token_pool.ex`:

```elixir
defmodule Druzhok.TokenPool do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Druzhok.Repo

  schema "tokens" do
    field :token, :string
    field :bot_username, :string
    belongs_to :instance, Druzhok.Instance
    timestamps()
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:token, :bot_username, :instance_id])
    |> validate_required([:token])
    |> unique_constraint(:token)
  end

  def allocate(instance_id) do
    Repo.transaction(fn ->
      case Repo.one(from t in __MODULE__, where: is_nil(t.instance_id), limit: 1) do
        nil -> Repo.rollback(:no_tokens_available)
        token ->
          token
          |> changeset(%{instance_id: instance_id})
          |> Repo.update!()
      end
    end)
  end

  def release(instance_id) do
    from(t in __MODULE__, where: t.instance_id == ^instance_id)
    |> Repo.update_all(set: [instance_id: nil])
    :ok
  end

  def list_all do
    Repo.all(from t in __MODULE__, order_by: [asc: :id], preload: [:instance])
  end

  def add(token, bot_username \\ nil) do
    %__MODULE__{}
    |> changeset(%{token: token, bot_username: bot_username})
    |> Repo.insert()
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd v4/druzhok && mix test apps/druzhok/test/druzhok/token_pool_test.exs
```

Expected: PASS (may need test config for Ecto sandbox — fix if needed).

- [ ] **Step 5: Implement Budget**

Create `v4/druzhok/apps/druzhok/lib/druzhok/budget.ex`:

```elixir
defmodule Druzhok.Budget do
  use Ecto.Schema
  import Ecto.Changeset
  alias Druzhok.Repo

  schema "budgets" do
    belongs_to :instance, Druzhok.Instance
    field :balance, :integer, default: 0
    field :lifetime_used, :integer, default: 0
    timestamps()
  end

  def changeset(budget, attrs) do
    budget
    |> cast(attrs, [:instance_id, :balance, :lifetime_used])
    |> validate_required([:instance_id, :balance])
    |> unique_constraint(:instance_id)
  end

  def check(instance_id) do
    case get_or_create(instance_id) do
      %{balance: b} when b > 0 -> {:ok, b}
      _ -> {:error, :exceeded}
    end
  end

  def deduct(instance_id, tokens) when tokens > 0 do
    budget = get_or_create(instance_id)
    budget
    |> changeset(%{
      balance: max(budget.balance - tokens, 0),
      lifetime_used: budget.lifetime_used + tokens,
    })
    |> Repo.update()
  end

  def add_credits(instance_id, amount) when amount > 0 do
    budget = get_or_create(instance_id)
    budget
    |> changeset(%{balance: budget.balance + amount})
    |> Repo.update()
  end

  def get_or_create(instance_id) do
    case Repo.get_by(__MODULE__, instance_id: instance_id) do
      nil ->
        %__MODULE__{}
        |> changeset(%{instance_id: instance_id, balance: 0})
        |> Repo.insert!()
      budget -> budget
    end
  end
end
```

- [ ] **Step 6: Implement Usage**

Create `v4/druzhok/apps/druzhok/lib/druzhok/usage.ex`:

```elixir
defmodule Druzhok.Usage do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Druzhok.Repo

  schema "usage_logs" do
    belongs_to :instance, Druzhok.Instance
    field :model, :string
    field :prompt_tokens, :integer
    field :completion_tokens, :integer
    field :total_tokens, :integer
    field :cost_cents, :integer, default: 0
    field :requested_model, :string
    field :resolved_model, :string
    field :provider, :string
    field :latency_ms, :integer
    timestamps(updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:instance_id, :model, :prompt_tokens, :completion_tokens,
                    :total_tokens, :cost_cents, :requested_model, :resolved_model,
                    :provider, :latency_ms])
    |> validate_required([:instance_id, :model, :prompt_tokens, :completion_tokens, :total_tokens])
  end

  def log(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  def daily_usage(instance_id, date \\ Date.utc_today()) do
    start_of_day = NaiveDateTime.new!(date, ~T[00:00:00])
    end_of_day = NaiveDateTime.new!(Date.add(date, 1), ~T[00:00:00])

    from(u in __MODULE__,
      where: u.instance_id == ^instance_id,
      where: u.inserted_at >= ^start_of_day and u.inserted_at < ^end_of_day,
      select: %{
        total_tokens: sum(u.total_tokens),
        total_cost: sum(u.cost_cents),
        request_count: count(u.id),
      }
    )
    |> Repo.one()
  end

  def recent(instance_id, limit \\ 50) do
    from(u in __MODULE__,
      where: u.instance_id == ^instance_id,
      order_by: [desc: :inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end
end
```

- [ ] **Step 7: Commit**

```
feat: add TokenPool, Budget, and Usage schemas
```

---

### Task 5: BotConfig — Env Var Builder

**Files:**
- Create: `v4/druzhok/apps/druzhok/lib/druzhok/bot_config.ex`
- Create: `v4/druzhok/apps/druzhok/lib/druzhok/model_access.ex`
- Test: `v4/druzhok/apps/druzhok/test/druzhok/bot_config_test.exs`

- [ ] **Step 1: Write BotConfig test**

Create `v4/druzhok/apps/druzhok/test/druzhok/bot_config_test.exs`:

```elixir
defmodule Druzhok.BotConfigTest do
  use ExUnit.Case

  test "builds zeroclaw env vars" do
    instance = %{
      name: "test-bot",
      tenant_key: "dk-test-abc123",
      telegram_token: "123:ABC",
      model: "claude-sonnet-4-20250514",
      bot_runtime: "zeroclaw",
      workspace: "/data/tenants/1/workspace",
    }

    env = Druzhok.BotConfig.build(instance)

    assert env["OPENAI_API_KEY"] == "dk-test-abc123"
    assert env["OPENAI_BASE_URL"] =~ "/v1"
    assert env["ZEROCLAW_CHANNELS_TELEGRAM_TOKEN"] == "123:ABC"
  end

  test "builds picoclaw env vars" do
    instance = %{
      name: "pico-bot",
      tenant_key: "dk-pico-xyz",
      telegram_token: "456:DEF",
      model: "claude-haiku",
      bot_runtime: "picoclaw",
      workspace: "/data/tenants/2/workspace",
    }

    env = Druzhok.BotConfig.build(instance)

    assert env["OPENAI_API_KEY"] == "dk-pico-xyz"
    assert env["PICOCLAW_CHANNELS_TELEGRAM_TOKEN"] == "456:DEF"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd v4/druzhok && mix test apps/druzhok/test/druzhok/bot_config_test.exs
```

- [ ] **Step 3: Implement BotConfig**

Create `v4/druzhok/apps/druzhok/lib/druzhok/bot_config.ex`:

```elixir
defmodule Druzhok.BotConfig do
  @moduledoc """
  Builds environment variable maps for bot containers.
  Each runtime (zeroclaw, picoclaw) has different env var conventions.
  """

  def build(instance) do
    proxy_host = System.get_env("LLM_PROXY_HOST") || "host.docker.internal"
    proxy_port = System.get_env("LLM_PROXY_PORT") || "4000"

    base = %{
      "OPENAI_BASE_URL" => "http://#{proxy_host}:#{proxy_port}/v1",
      "OPENAI_API_KEY" => instance.tenant_key,
      "TZ" => Map.get(instance, :timezone, "UTC"),
    }

    runtime_env = case to_string(instance.bot_runtime) do
      "picoclaw" -> picoclaw_env(instance)
      "zeroclaw" -> zeroclaw_env(instance)
      _ -> generic_env(instance)
    end

    Map.merge(base, runtime_env)
  end

  defp picoclaw_env(instance) do
    env = %{
      "PICOCLAW_AGENTS_DEFAULTS_MODEL_NAME" => instance.model || "default",
    }

    if instance.telegram_token do
      Map.merge(env, %{
        "PICOCLAW_CHANNELS_TELEGRAM_ENABLED" => "true",
        "PICOCLAW_CHANNELS_TELEGRAM_TOKEN" => instance.telegram_token,
      })
    else
      env
    end
  end

  defp zeroclaw_env(instance) do
    env = %{
      "ZEROCLAW_AGENT_MODEL" => instance.model || "default",
      "ZEROCLAW_PROVIDER_TYPE" => "compatible",
    }

    if instance.telegram_token do
      Map.merge(env, %{
        "ZEROCLAW_CHANNELS_TELEGRAM_ENABLED" => "true",
        "ZEROCLAW_CHANNELS_TELEGRAM_TOKEN" => instance.telegram_token,
      })
    else
      env
    end
  end

  defp generic_env(instance) do
    %{
      "BOT_MODEL" => instance.model || "default",
      "TELEGRAM_TOKEN" => instance.telegram_token || "",
    }
  end

  def docker_image(instance) do
    case to_string(instance.bot_runtime) do
      "picoclaw" -> System.get_env("PICOCLAW_IMAGE") || "picoclaw:latest"
      "zeroclaw" -> System.get_env("ZEROCLAW_IMAGE") || "zeroclaw:latest"
      custom -> custom
    end
  end
end
```

- [ ] **Step 4: Implement ModelAccess**

Create `v4/druzhok/apps/druzhok/lib/druzhok/model_access.ex`:

```elixir
defmodule Druzhok.ModelAccess do
  @moduledoc """
  Plan-based model gating. Checks if a model is allowed for a tenant,
  and provides downgrade logic.
  """

  @model_tiers %{
    "claude-haiku" => 1,
    "claude-haiku-3-5" => 1,
    "claude-haiku-4-5" => 1,
    "deepseek-r1" => 1,
    "deepseek-chat" => 1,
    "claude-sonnet" => 2,
    "claude-sonnet-4-20250514" => 2,
    "claude-sonnet-4-6" => 2,
    "gpt-4o" => 2,
    "gpt-4o-mini" => 1,
    "claude-opus" => 3,
    "claude-opus-4-6" => 3,
  }

  @plan_max_tier %{
    "free" => 1,
    "pro" => 2,
    "enterprise" => 3,
  }

  def check(plan, requested_model) do
    max_tier = Map.get(@plan_max_tier, to_string(plan), 1)
    model_tier = get_tier(requested_model)

    if model_tier <= max_tier do
      {:ok, requested_model}
    else
      {:downgrade, best_allowed(requested_model, max_tier)}
    end
  end

  defp get_tier(model) do
    # Exact match first, then prefix match
    Map.get(@model_tiers, model) ||
      Enum.find_value(@model_tiers, 1, fn {prefix, tier} ->
        if String.starts_with?(model, prefix), do: tier
      end)
  end

  defp best_allowed(requested_model, max_tier) do
    # Find the highest-tier model in the same family that's allowed
    family = model_family(requested_model)

    @model_tiers
    |> Enum.filter(fn {name, tier} -> tier <= max_tier and model_family(name) == family end)
    |> Enum.sort_by(fn {_, tier} -> -tier end)
    |> case do
      [{name, _} | _] -> name
      [] -> "claude-haiku"
    end
  end

  defp model_family(model) do
    cond do
      String.contains?(model, "claude") -> :claude
      String.contains?(model, "gpt") -> :openai
      String.contains?(model, "deepseek") -> :deepseek
      true -> :other
    end
  end
end
```

- [ ] **Step 5: Run tests**

```bash
cd v4/druzhok && mix test apps/druzhok/test/druzhok/bot_config_test.exs
```

Expected: PASS

- [ ] **Step 6: Commit**

```
feat: add BotConfig env builder and ModelAccess gating
```

---

### Task 6: BotManager — Container Lifecycle

**Files:**
- Create: `v4/druzhok/apps/druzhok/lib/druzhok/bot_manager.ex`
- Create: `v4/druzhok/apps/druzhok/lib/druzhok/health_monitor.ex`
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/application.ex`

- [ ] **Step 1: Implement BotManager**

Create `v4/druzhok/apps/druzhok/lib/druzhok/bot_manager.ex`:

```elixir
defmodule Druzhok.BotManager do
  @moduledoc """
  Top-level API for bot container lifecycle.
  Creates, starts, stops, restarts Docker containers running bot runtimes.
  """

  alias Druzhok.{Instance, InstanceManager, BotConfig, TokenPool, Budget, Repo}
  require Logger

  @data_root System.get_env("DRUZHOK_DATA_ROOT") || "/data/tenants"

  def create(name, opts) do
    workspace = Path.join([@data_root, name, "workspace"])

    token_result = if opts[:telegram_token] do
      {:ok, %{token: opts[:telegram_token]}}
    else
      TokenPool.allocate(0)  # temporary ID, updated after DB insert
    end

    case token_result do
      {:ok, token_record} ->
        tenant_key = generate_tenant_key(name)

        config = Map.merge(opts, %{
          workspace: workspace,
          telegram_token: token_record.token,
          tenant_key: tenant_key,
          sandbox: "docker",
        })

        case InstanceManager.create(name, config) do
          {:ok, instance_info} ->
            Budget.get_or_create(get_instance_id(name))
            start(name)
            {:ok, instance_info}

          error -> error
        end

      {:error, :no_tokens_available} ->
        {:error, "No Telegram tokens available in pool"}
    end
  end

  def start(name) do
    case Repo.get_by(Instance, name: name) do
      nil -> {:error, :not_found}
      instance ->
        env = BotConfig.build(instance)
        image = BotConfig.docker_image(instance)

        case start_container(name, image, env, instance.workspace) do
          {:ok, container_id} ->
            Logger.info("Started bot container #{name}: #{container_id}")
            Druzhok.HealthMonitor.register(name, container_id)
            Repo.update(Instance.changeset(instance, %{active: true}))
            {:ok, container_id}

          {:error, reason} ->
            Logger.error("Failed to start bot #{name}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  def stop(name) do
    stop_container(name)
    Druzhok.HealthMonitor.unregister(name)
    case Repo.get_by(Instance, name: name) do
      nil -> :ok
      instance -> Repo.update(Instance.changeset(instance, %{active: false}))
    end
    :ok
  end

  def restart(name) do
    stop(name)
    Process.sleep(1_000)
    start(name)
  end

  def delete(name) do
    stop(name)
    case Repo.get_by(Instance, name: name) do
      nil -> :ok
      instance ->
        TokenPool.release(instance.id)
        Repo.delete(instance)
    end
    :ok
  end

  def status(name) do
    {output, exit_code} = System.cmd("docker", ["inspect", "--format", "{{.State.Status}}", container_name(name)], stderr_to_stdout: true)
    if exit_code == 0, do: String.trim(output), else: "not_found"
  end

  # Docker CLI helpers

  defp start_container(name, image, env, workspace) do
    env_args = Enum.flat_map(env, fn {k, v} -> ["-e", "#{k}=#{v}"] end)

    args = ["run", "-d",
      "--name", container_name(name),
      "--network", "host",
      "--restart", "unless-stopped",
      "-v", "#{workspace}:/data",
    ] ++ env_args ++ [image, "gateway"]

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {container_id, 0} -> {:ok, String.trim(container_id)}
      {error, _} -> {:error, String.trim(error)}
    end
  end

  defp stop_container(name) do
    System.cmd("docker", ["rm", "-f", container_name(name)], stderr_to_stdout: true)
    :ok
  end

  defp container_name(name), do: "druzhok-bot-#{name}"

  defp generate_tenant_key(name) do
    random = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    "dk-#{name}-#{random}"
  end

  defp get_instance_id(name) do
    case Repo.get_by(Instance, name: name) do
      nil -> nil
      inst -> inst.id
    end
  end
end
```

- [ ] **Step 2: Implement HealthMonitor**

Create `v4/druzhok/apps/druzhok/lib/druzhok/health_monitor.ex`:

```elixir
defmodule Druzhok.HealthMonitor do
  @moduledoc """
  Periodically polls /health on each running bot container.
  Restarts containers that fail 3 consecutive health checks.
  """
  use GenServer
  require Logger

  @check_interval 30_000
  @max_failures 3

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def register(name, container_id) do
    GenServer.cast(__MODULE__, {:register, name, container_id})
  end

  def unregister(name) do
    GenServer.cast(__MODULE__, {:unregister, name})
  end

  def list do
    GenServer.call(__MODULE__, :list)
  end

  # Server

  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %{bots: %{}}}
  end

  @impl true
  def handle_cast({:register, name, container_id}, state) do
    bots = Map.put(state.bots, name, %{container_id: container_id, failures: 0, status: :healthy})
    {:noreply, %{state | bots: bots}}
  end

  @impl true
  def handle_cast({:unregister, name}, state) do
    {:noreply, %{state | bots: Map.delete(state.bots, name)}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state.bots, state}
  end

  @impl true
  def handle_info(:check_health, state) do
    bots = state.bots
    |> Enum.map(fn {name, info} -> {name, check_one(name, info)} end)
    |> Map.new()

    schedule_check()
    {:noreply, %{state | bots: bots}}
  end

  defp check_one(name, info) do
    case do_health_check(name) do
      :ok ->
        if info.failures > 0, do: Logger.info("Bot #{name} recovered")
        %{info | failures: 0, status: :healthy}

      :error ->
        failures = info.failures + 1
        Logger.warning("Bot #{name} health check failed (#{failures}/#{@max_failures})")

        if failures >= @max_failures do
          Logger.error("Bot #{name} unhealthy, attempting restart")
          Druzhok.Events.broadcast(name, %{type: :health_restart})
          Task.start(fn -> Druzhok.BotManager.restart(name) end)
          %{info | failures: 0, status: :restarting}
        else
          %{info | failures: failures, status: :degraded}
        end
    end
  end

  defp do_health_check(name) do
    # Bot gateway listens on a per-instance port or we check Docker health
    case System.cmd("docker", ["inspect", "--format", "{{.State.Health.Status}}",
                     "druzhok-bot-#{name}"], stderr_to_stdout: true) do
      {"healthy\n", 0} -> :ok
      {"unhealthy\n", 0} -> :error
      # No healthcheck configured — check if running
      _ ->
        case System.cmd("docker", ["inspect", "--format", "{{.State.Running}}",
                         "druzhok-bot-#{name}"], stderr_to_stdout: true) do
          {"true\n", 0} -> :ok
          _ -> :error
        end
    end
  end

  defp schedule_check do
    Process.send_after(self(), :check_health, @check_interval)
  end
end
```

- [ ] **Step 3: Update Application to start HealthMonitor and Finch**

Update `v4/druzhok/apps/druzhok/lib/druzhok/application.ex`:

```elixir
defmodule Druzhok.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children = [
      Druzhok.Repo,
      {Registry, keys: :unique, name: Druzhok.Registry},
      {DynamicSupervisor, name: Druzhok.InstanceDynSup, strategy: :one_for_one},
      {Finch, name: Druzhok.Finch, pools: finch_pools()},
      Druzhok.HealthMonitor,
    ]

    opts = [strategy: :one_for_one, name: Druzhok.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp finch_pools do
    case Application.get_env(:druzhok, :http_proxy_url) do
      nil -> %{}
      proxy_url ->
        uri = URI.parse(proxy_url)
        %{default: [conn_opts: [proxy: {String.to_atom(uri.scheme), uri.host, uri.port, []}]]}
    end
  end
end
```

- [ ] **Step 4: Verify compilation**

```bash
cd v4/druzhok && mix compile
```

Expected: Clean compilation.

- [ ] **Step 5: Commit**

```
feat: add BotManager container lifecycle and HealthMonitor
```

---

### Task 7: LLM Proxy Controller

**Files:**
- Create: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/plugs/llm_auth.ex`
- Create: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/llm_format.ex`
- Create: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex`
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/router.ex`

- [ ] **Step 1: Create LLM auth plug**

Create `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/plugs/llm_auth.ex`:

```elixir
defmodule DruzhokWebWeb.Plugs.LlmAuth do
  @moduledoc """
  Authenticates LLM proxy requests via Bearer token (tenant key).
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> tenant_key] ->
        case Druzhok.Repo.get_by(Druzhok.Instance, tenant_key: tenant_key) do
          nil ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(401, Jason.encode!(%{error: %{message: "Invalid API key", type: "authentication_error"}}))
            |> halt()

          instance ->
            assign(conn, :instance, instance)
        end

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: %{message: "Missing Authorization header", type: "authentication_error"}}))
        |> halt()
    end
  end
end
```

- [ ] **Step 2: Create LLM format translator**

Create `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/llm_format.ex`:

```elixir
defmodule DruzhokWebWeb.LlmFormat do
  @moduledoc """
  Translates between OpenAI chat format and provider-specific formats.
  OpenRouter and Nebius accept OpenAI format natively.
  Anthropic requires message format translation.
  """

  def route_provider(model) do
    cond do
      String.starts_with?(model, "claude") -> :anthropic
      String.starts_with?(model, "gpt") -> :openrouter
      String.starts_with?(model, "deepseek") -> :nebius
      String.starts_with?(model, "glm") -> :nebius
      String.starts_with?(model, "Qwen") -> :nebius
      true -> :openrouter
    end
  end

  def provider_url(provider) do
    case provider do
      :anthropic -> Application.get_env(:druzhok, :anthropic_api_url) || "https://api.anthropic.com"
      :openrouter -> Application.get_env(:druzhok, :openrouter_api_url) || "https://openrouter.ai/api/v1"
      :nebius -> Application.get_env(:druzhok, :nebius_api_url) || "https://api.tokenfactory.us-central1.nebius.com/v1"
    end
  end

  def provider_key(provider) do
    case provider do
      :anthropic -> Application.get_env(:druzhok, :anthropic_api_key)
      :openrouter -> Application.get_env(:druzhok, :openrouter_api_key)
      :nebius -> Application.get_env(:druzhok, :nebius_api_key)
    end
  end

  def build_request(:anthropic, body) do
    messages = body["messages"] || []
    {system_msgs, chat_msgs} = Enum.split_with(messages, &(&1["role"] == "system"))

    system_text = system_msgs
    |> Enum.map(& &1["content"])
    |> Enum.join("\n\n")

    anthropic_body = %{
      "model" => body["model"],
      "messages" => Enum.map(chat_msgs, &translate_message/1),
      "max_tokens" => body["max_tokens"] || 4096,
      "stream" => body["stream"] || false,
    }

    anthropic_body = if system_text != "", do: Map.put(anthropic_body, "system", system_text), else: anthropic_body
    if body["temperature"], do: Map.put(anthropic_body, "temperature", body["temperature"]), else: anthropic_body
  end

  def build_request(_provider, body) do
    # OpenRouter and Nebius accept OpenAI format
    body
  end

  def request_url(:anthropic, _), do: "/v1/messages"
  def request_url(_, _), do: "/v1/chat/completions"

  def request_headers(:anthropic, api_key) do
    [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"},
    ]
  end

  def request_headers(_, api_key) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"},
    ]
  end

  def extract_usage(:anthropic, response_body) do
    usage = response_body["usage"] || %{}
    %{
      prompt_tokens: usage["input_tokens"] || 0,
      completion_tokens: usage["output_tokens"] || 0,
    }
  end

  def extract_usage(_, response_body) do
    usage = response_body["usage"] || %{}
    %{
      prompt_tokens: usage["prompt_tokens"] || 0,
      completion_tokens: usage["completion_tokens"] || 0,
    }
  end

  defp translate_message(%{"role" => role, "content" => content}) when is_binary(content) do
    %{"role" => role, "content" => content}
  end

  defp translate_message(msg), do: msg
end
```

- [ ] **Step 3: Create LLM proxy controller**

Create `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex`:

```elixir
defmodule DruzhokWebWeb.LlmProxyController do
  use DruzhokWebWeb, :controller
  alias DruzhokWebWeb.LlmFormat
  alias Druzhok.{Budget, Usage, ModelAccess}
  require Logger

  def chat_completions(conn, _params) do
    instance = conn.assigns.instance
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    body = Jason.decode!(body)

    requested_model = body["model"] || "default"
    plan = instance.plan || "free"
    stream = body["stream"] == true

    # 1. Check budget
    case Budget.check(instance.id) do
      {:error, :exceeded} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(429, Jason.encode!(%{error: %{message: "Token budget exceeded", type: "insufficient_quota"}}))

      {:ok, _remaining} ->
        # 2. Model access check
        {resolved_model, _} = case ModelAccess.check(plan, requested_model) do
          {:ok, model} -> {model, requested_model}
          {:downgrade, model} ->
            Logger.info("Downgraded #{requested_model} → #{model} for tenant #{instance.tenant_key}")
            {model, requested_model}
        end

        body = Map.put(body, "model", resolved_model)

        # 3. Route to provider
        provider = LlmFormat.route_provider(resolved_model)
        api_key = LlmFormat.provider_key(provider)
        base_url = LlmFormat.provider_url(provider)
        path = LlmFormat.request_url(provider, body)
        url = base_url <> path

        provider_body = LlmFormat.build_request(provider, body)
        headers = LlmFormat.request_headers(provider, api_key)

        started_at = System.monotonic_time(:millisecond)

        if stream do
          stream_proxy(conn, instance, url, headers, provider_body, provider, requested_model, resolved_model, started_at)
        else
          sync_proxy(conn, instance, url, headers, provider_body, provider, requested_model, resolved_model, started_at)
        end
    end
  end

  defp sync_proxy(conn, instance, url, headers, body, provider, requested_model, resolved_model, started_at) do
    request = Finch.build(:post, url, headers, Jason.encode!(body))

    case Finch.request(request, Druzhok.Finch, receive_timeout: 120_000) do
      {:ok, %Finch.Response{status: status, body: resp_body, headers: resp_headers}} ->
        latency = System.monotonic_time(:millisecond) - started_at
        decoded = Jason.decode!(resp_body)
        usage = LlmFormat.extract_usage(provider, decoded)
        total = usage.prompt_tokens + usage.completion_tokens

        # Deduct and log
        Budget.deduct(instance.id, total)
        Usage.log(%{
          instance_id: instance.id,
          model: resolved_model,
          prompt_tokens: usage.prompt_tokens,
          completion_tokens: usage.completion_tokens,
          total_tokens: total,
          requested_model: requested_model,
          resolved_model: resolved_model,
          provider: to_string(provider),
          latency_ms: latency,
        })

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, resp_body)

      {:error, reason} ->
        Logger.error("LLM proxy error: #{inspect(reason)}")
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(502, Jason.encode!(%{error: %{message: "Provider unavailable", type: "server_error"}}))
    end
  end

  defp stream_proxy(conn, instance, url, headers, body, provider, requested_model, resolved_model, started_at) do
    request = Finch.build(:post, url, headers, Jason.encode!(body))

    conn = conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)

    # Stream chunks through, accumulate usage from final chunk
    usage_ref = make_ref()
    Process.put(usage_ref, %{prompt_tokens: 0, completion_tokens: 0})

    result = Finch.stream(request, Druzhok.Finch, conn, fn
      {:status, status}, conn -> conn
      {:headers, resp_headers}, conn -> conn
      {:data, data}, conn ->
        # Try to extract usage from SSE data lines
        for line <- String.split(data, "\n"), String.starts_with?(line, "data: ") do
          json_str = String.trim_leading(line, "data: ")
          if json_str != "[DONE]" do
            case Jason.decode(json_str) do
              {:ok, %{"usage" => usage}} when is_map(usage) ->
                Process.put(usage_ref, LlmFormat.extract_usage(provider, %{"usage" => usage}))
              _ -> :ok
            end
          end
        end

        case Plug.Conn.chunk(conn, data) do
          {:ok, conn} -> conn
          {:error, _} -> conn
        end
    end, receive_timeout: 120_000)

    # Log usage after stream completes
    latency = System.monotonic_time(:millisecond) - started_at
    usage = Process.get(usage_ref, %{prompt_tokens: 0, completion_tokens: 0})
    total = usage.prompt_tokens + usage.completion_tokens

    if total > 0 do
      Budget.deduct(instance.id, total)
      Usage.log(%{
        instance_id: instance.id,
        model: resolved_model,
        prompt_tokens: usage.prompt_tokens,
        completion_tokens: usage.completion_tokens,
        total_tokens: total,
        requested_model: requested_model,
        resolved_model: resolved_model,
        provider: to_string(provider),
        latency_ms: latency,
      })
    end

    case result do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end
end
```

- [ ] **Step 4: Add proxy route to router**

In `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/router.ex`, add before the public scope:

```elixir
  # LLM Proxy API (used by bot containers)
  pipeline :llm_api do
    plug :accepts, ["json"]
    plug DruzhokWebWeb.Plugs.LlmAuth
  end

  scope "/v1", DruzhokWebWeb do
    pipe_through :llm_api

    post "/chat/completions", LlmProxyController, :chat_completions
  end
```

- [ ] **Step 5: Increase body read limit for LLM requests**

In `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/endpoint.ex`, find the Plug.Parsers section and increase the body limit, or handle it in the controller (we already use `read_body` directly).

Add to the endpoint config in `config.exs`:

```elixir
config :druzhok_web, DruzhokWebWeb.Endpoint,
  # ... existing config ...
  http: [
    protocol_options: [max_request_line_length: 16_384, max_header_value_length: 16_384]
  ]
```

- [ ] **Step 6: Verify compilation**

```bash
cd v4/druzhok && mix compile
```

- [ ] **Step 7: Commit**

```
feat: add LLM proxy controller with billing, model gating, and streaming
```

---

### Task 8: Update Dashboard for Orchestrator

**Files:**
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex`

This task adapts the existing dashboard to work with the orchestrator. The dashboard is 840 lines and heavily references PiCore concepts. Rather than rewriting from scratch, we strip PiCore-specific parts and add orchestrator views.

- [ ] **Step 1: Remove PiCore event handling from dashboard**

In `dashboard_live.ex`, remove or comment out `handle_info` clauses that reference:
- `:pi_delta`
- `:pi_tool_status`
- `PiCore.Session.*`
- Tool execution events
- Session-specific events

Keep: instance list, model selection, create/delete instance, settings, events log (will show health events instead).

- [ ] **Step 2: Update instance creation to use BotManager**

Replace calls to `InstanceManager.create` with `BotManager.create`:

```elixir
# In handle_event("create_instance", ...)
case Druzhok.BotManager.create(name, %{
  model: model,
  bot_runtime: runtime,  # from form
}) do
  {:ok, info} -> ...
  {:error, reason} -> ...
end
```

- [ ] **Step 3: Add container status to instance list**

In the mount/refresh logic, augment instance list with container status:

```elixir
instances = Druzhok.InstanceManager.list()
|> Enum.map(fn inst ->
  Map.put(inst, :container_status, Druzhok.BotManager.status(inst.name))
end)
```

- [ ] **Step 4: Add bot_runtime picker to create form**

Add a select field for runtime in the create instance form:

```heex
<select name="bot_runtime" class="...">
  <option value="zeroclaw">ZeroClaw (Rust)</option>
  <option value="picoclaw">PicoClaw (Go)</option>
</select>
```

- [ ] **Step 5: Add budget display per instance**

Show remaining tokens and add-credits button in the instance detail view.

- [ ] **Step 6: Remove dashboard tabs that no longer apply**

Remove or stub:
- Event log tab (replace with health events)
- Skills tab (managed by bot internally)
- File browser (can keep — reads workspace directory directly)

Keep:
- Security tab (pairing, groups)
- Usage tab (now from Usage schema)
- Errors tab (crash logs)

- [ ] **Step 7: Verify dashboard loads**

```bash
cd v4/druzhok && mix phx.server
```

Open http://localhost:4000 and verify the dashboard renders without errors.

- [ ] **Step 8: Commit**

```
feat: update dashboard for v4 orchestrator
```

---

### Task 9: Clean Up and Final Integration

**Files:**
- Modify: various (cleanup pass)

- [ ] **Step 1: Remove Scheduler PiCore references**

Read `scheduler.ex`, remove `PiCore.Session.prompt_heartbeat` and `PiCore.Session.prompt` calls. Replace with HTTP POST to bot's gateway (if the bot runtime supports it) or remove heartbeat triggering entirely (bots handle their own HEARTBEAT.md).

For now, the scheduler can just log:

```elixir
defp trigger_heartbeat(name) do
  Logger.info("Heartbeat for #{name} — handled by bot internally")
end
```

- [ ] **Step 2: Remove InstanceWatcher PiCore references**

Check `instance_watcher.ex` for references to PiCore or Telegram. Update to monitor Docker containers instead.

- [ ] **Step 3: Remove unused Telegram modules if they have PiCore deps**

Check `telegram/api.ex` and `telegram/format.ex`. Keep if they compile independently (useful for admin notifications). Remove if they depend on PiCore.

- [ ] **Step 4: Clean up config/dev.exs and config/test.exs**

Remove any pi_core references.

- [ ] **Step 5: Run full test suite**

```bash
cd v4/druzhok && mix test
```

Fix any failing tests. Delete test files for deleted modules.

- [ ] **Step 6: Run full compilation check**

```bash
cd v4/druzhok && mix compile --warnings-as-errors 2>&1
```

Fix all warnings.

- [ ] **Step 7: Verify end-to-end flow**

1. Start the app: `cd v4/druzhok && mix phx.server`
2. Open dashboard, create a bot instance
3. Verify Docker container starts (or fails gracefully if no image)
4. Verify health monitoring logs
5. Test LLM proxy: `curl -X POST http://localhost:4000/v1/chat/completions -H "Authorization: Bearer dk-test-..." -H "Content-Type: application/json" -d '{"model":"claude-haiku","messages":[{"role":"user","content":"hello"}]}'`

- [ ] **Step 8: Commit**

```
feat: v4 orchestrator — clean up and integration
```

---

### Task 10: Commit Design Docs

- [ ] **Step 1: Commit spec and plan**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add docs/superpowers/specs/2026-03-28-v4-orchestrator-design.md
git add docs/superpowers/plans/2026-03-28-v4-orchestrator.md
git commit -m "docs: v4 orchestrator design spec and implementation plan"
```
