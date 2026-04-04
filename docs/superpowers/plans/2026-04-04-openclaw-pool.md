# OpenClaw Multi-Tenant Pool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pool multiple OpenClaw users into shared containers (10 per pool) to reduce RAM from 50 GB to ~6 GB for 100 users.

**Architecture:** New `PoolManager` GenServer assigns instances to pools. Replace the single-tenant `OpenClaw` adapter with pool-aware logic. Each pool container runs one OpenClaw gateway with N agents, per-agent providers, and sandbox isolation.

**Tech Stack:** Elixir/Phoenix, Ecto/SQLite, Docker, OpenClaw JSON config

**Spec:** `docs/superpowers/specs/2026-04-04-openclaw-pool-design.md`

---

## File Structure

### New files
- `apps/druzhok/lib/druzhok/pool.ex` — Ecto schema for pools table
- `apps/druzhok/lib/druzhok/pool_manager.ex` — GenServer managing pool lifecycle
- `apps/druzhok/lib/druzhok/pool_config.ex` — OpenClaw JSON config generator for pools
- `apps/druzhok/priv/repo/migrations/TIMESTAMP_create_pools.exs` — DB migration
- `apps/druzhok/test/druzhok/pool_manager_test.exs` — PoolManager unit tests
- `apps/druzhok/test/druzhok/pool_config_test.exs` — Config generation tests

### Modified files
- `apps/druzhok/lib/druzhok/instance.ex` — Add `pool_id` field
- `apps/druzhok/lib/druzhok/runtime.ex` — Add `pooled?/0` callback
- `apps/druzhok/lib/druzhok/runtime/open_claw.ex` — Return `pooled?() = true`, delegate to PoolManager
- `apps/druzhok/lib/druzhok/runtime/zero_claw.ex` — Add `pooled?() = false`
- `apps/druzhok/lib/druzhok/runtime/pico_claw.ex` — Add `pooled?() = false`
- `apps/druzhok/lib/druzhok/runtime/null_claw.ex` — Add `pooled?() = false`
- `apps/druzhok/lib/druzhok/bot_manager.ex` — Branch on `pooled?/0`
- `apps/druzhok/lib/druzhok/health_monitor.ex` — Support pool containers
- `apps/druzhok/lib/druzhok/log_watcher.ex` — Support shared pool container
- `apps/druzhok/lib/druzhok/application.ex` — Add PoolManager to supervision tree
- `apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex` — Pool sidebar hierarchy

---

### Task 1: Database Migration — pools table + instance.pool_id

**Files:**
- Create: `apps/druzhok/priv/repo/migrations/TIMESTAMP_create_pools.exs`

- [ ] **Step 1: Create migration file**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix ecto.gen.migration create_pools
```

- [ ] **Step 2: Write migration**

Open the generated file and write:

```elixir
defmodule Druzhok.Repo.Migrations.CreatePools do
  use Ecto.Migration

  def change do
    create table(:pools) do
      add :name, :string, null: false
      add :container, :string, null: false
      add :port, :integer, null: false
      add :max_tenants, :integer, null: false, default: 10
      add :status, :string, null: false, default: "stopped"

      timestamps()
    end

    create unique_index(:pools, [:name])
    create unique_index(:pools, [:container])
    create unique_index(:pools, [:port])

    alter table(:instances) do
      add :pool_id, references(:pools, on_delete: :nilify_all)
    end

    create index(:instances, [:pool_id])
  end
end
```

- [ ] **Step 3: Run migration**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix ecto.migrate
```

Expected: migration runs successfully, no errors.

- [ ] **Step 4: Commit**

```
feat: add pools table and instance.pool_id migration
```

---

### Task 2: Pool Ecto Schema

**Files:**
- Create: `apps/druzhok/lib/druzhok/pool.ex`
- Modify: `apps/druzhok/lib/druzhok/instance.ex`

- [ ] **Step 1: Create Pool schema**

```elixir
defmodule Druzhok.Pool do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Druzhok.{Repo, Instance}

  schema "pools" do
    field :name, :string
    field :container, :string
    field :port, :integer
    field :max_tenants, :integer, default: 10
    field :status, :string, default: "stopped"

    has_many :instances, Instance, foreign_key: :pool_id

    timestamps()
  end

  def changeset(pool, attrs) do
    pool
    |> cast(attrs, [:name, :container, :port, :max_tenants, :status])
    |> validate_required([:name, :container, :port])
    |> unique_constraint(:name)
    |> unique_constraint(:container)
    |> unique_constraint(:port)
  end

  def with_instances(pool_id) do
    Repo.get(Pool, pool_id) |> Repo.preload(:instances)
  end

  def active_pools do
    from(p in __MODULE__, where: p.status in ["running", "starting"], preload: [:instances])
    |> Repo.all()
  end

  def pool_with_capacity(max_tenants \\ 10) do
    from(p in __MODULE__,
      where: p.status == "running",
      preload: [:instances]
    )
    |> Repo.all()
    |> Enum.find(fn pool -> length(pool.instances) < pool.max_tenants end)
  end

  def next_port do
    base = 18800

    case Repo.one(from p in __MODULE__, select: max(p.port)) do
      nil -> base
      max_port -> max_port + 1
    end
  end

  def next_name do
    case Repo.one(from p in __MODULE__, select: count(p.id)) do
      0 -> "openclaw-pool-1"
      n -> "openclaw-pool-#{n + 1}"
    end
  end
end
```

- [ ] **Step 2: Add pool_id to Instance schema**

In `apps/druzhok/lib/druzhok/instance.ex`, add to the schema block:

```elixir
field :pool_id, :id
```

And add `:pool_id` to the cast list in `changeset/2`.

- [ ] **Step 3: Verify compilation**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix compile
```

Expected: no errors.

- [ ] **Step 4: Commit**

```
feat: add Pool schema and Instance.pool_id field
```

---

### Task 3: Pool Config Generator

**Files:**
- Create: `apps/druzhok/lib/druzhok/pool_config.ex`
- Create: `apps/druzhok/test/druzhok/pool_config_test.exs`

- [ ] **Step 1: Write config generator test**

```elixir
defmodule Druzhok.PoolConfigTest do
  use ExUnit.Case, async: true

  alias Druzhok.PoolConfig

  test "generates config for single instance" do
    instances = [
      %{
        name: "alice",
        model: "gpt-4o",
        on_demand_model: nil,
        tenant_key: "dk-alice-xxx",
        telegram_token: "111:AAA",
        workspace: "/data/instances/alice/workspace"
      }
    ]

    config = PoolConfig.build(instances, port: 18800)

    assert config["gateway"]["port"] == 18800
    assert config["gateway"]["bind"] == "0.0.0.0"
    assert config["session"]["dmScope"] == "per-channel-peer"

    assert Map.has_key?(config["models"]["providers"], "tenant-alice")
    provider = config["models"]["providers"]["tenant-alice"]
    assert provider["apiKey"] == "dk-alice-xxx"

    agents = config["agents"]["list"]
    assert length(agents) == 1
    assert hd(agents)["id"] == "alice"
    assert hd(agents)["workspace"] == "/data/workspaces/alice"

    bindings = config["bindings"]
    assert length(bindings) == 1
    assert hd(bindings)["agentId"] == "alice"
    assert hd(bindings)["match"]["accountId"] == "alice"
  end

  test "generates config for multiple instances" do
    instances = [
      %{name: "alice", model: "gpt-4o", on_demand_model: nil, tenant_key: "dk-alice", telegram_token: "111:A", workspace: "/data/instances/alice/workspace"},
      %{name: "bob", model: "claude-sonnet", on_demand_model: "claude-opus", tenant_key: "dk-bob", telegram_token: "222:B", workspace: "/data/instances/bob/workspace"}
    ]

    config = PoolConfig.build(instances, port: 18801)

    assert length(config["agents"]["list"]) == 2
    assert length(config["bindings"]) == 2
    assert map_size(config["models"]["providers"]) == 2
    assert map_size(config["channels"]["telegram"]["accounts"]) == 2

    bob_provider = config["models"]["providers"]["tenant-bob"]
    bob_models = bob_provider["models"]
    assert length(bob_models) == 2
    assert Enum.any?(bob_models, &(&1["name"] == "smart"))
  end

  test "generates config with sandbox enabled" do
    instances = [%{name: "alice", model: "gpt-4o", on_demand_model: nil, tenant_key: "dk-alice", telegram_token: "111:A", workspace: "/data/instances/alice/workspace"}]
    config = PoolConfig.build(instances, port: 18800)

    assert config["agents"]["defaults"]["sandbox"]["mode"] == "all"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix test apps/druzhok/test/druzhok/pool_config_test.exs
```

Expected: FAIL — module PoolConfig not found.

- [ ] **Step 3: Write PoolConfig module**

```elixir
defmodule Druzhok.PoolConfig do
  @moduledoc """
  Generates OpenClaw multi-agent JSON config for a pool of instances.
  """

  alias Druzhok.Runtime

  def build(instances, opts \\ []) do
    port = Keyword.get(opts, :port, 18800)
    proxy_host = Runtime.proxy_host()

    %{
      "gateway" => %{
        "bind" => "0.0.0.0",
        "port" => port,
        "reload" => %{"mode" => "hybrid"}
      },
      "session" => %{
        "dmScope" => "per-channel-peer"
      },
      "models" => %{
        "providers" => build_providers(instances, proxy_host)
      },
      "agents" => %{
        "defaults" => %{
          "sandbox" => %{"mode" => "all"}
        },
        "list" => Enum.map(instances, &build_agent/1)
      },
      "channels" => %{
        "telegram" => %{
          "accounts" => build_telegram_accounts(instances)
        }
      },
      "bindings" => Enum.map(instances, &build_binding/1)
    }
  end

  defp build_providers(instances, proxy_host) do
    Map.new(instances, fn inst ->
      {"tenant-#{inst.name}", %{
        "baseUrl" => "http://#{proxy_host}:4000/v1",
        "apiKey" => inst.tenant_key,
        "api" => "openai-completions",
        "models" => build_model_list(inst.model, inst.on_demand_model)
      }}
    end)
  end

  defp build_model_list(model, nil) do
    [%{"id" => model, "name" => "default"}]
  end

  defp build_model_list(model, on_demand_model) do
    [
      %{"id" => model, "name" => "default"},
      %{"id" => on_demand_model, "name" => "smart"}
    ]
  end

  defp build_agent(inst) do
    %{
      "id" => inst.name,
      "model" => "tenant-#{inst.name}/#{inst.model}",
      "workspace" => "/data/workspaces/#{inst.name}"
    }
  end

  defp build_telegram_accounts(instances) do
    Map.new(instances, fn inst ->
      {inst.name, %{"botToken" => inst.telegram_token}}
    end)
  end

  defp build_binding(inst) do
    %{
      "agentId" => inst.name,
      "match" => %{
        "channel" => "telegram",
        "accountId" => inst.name
      }
    }
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix test apps/druzhok/test/druzhok/pool_config_test.exs
```

Expected: 3 tests, 0 failures.

- [ ] **Step 5: Commit**

```
feat: add PoolConfig module for multi-agent OpenClaw config generation
```

---

### Task 4: PoolManager GenServer

**Files:**
- Create: `apps/druzhok/lib/druzhok/pool_manager.ex`

- [ ] **Step 1: Write PoolManager**

```elixir
defmodule Druzhok.PoolManager do
  use GenServer
  require Logger

  alias Druzhok.{Repo, Pool, Instance, PoolConfig, HealthMonitor}

  @health_timeout 10_000
  @health_retries 10

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def assign(instance) do
    GenServer.call(__MODULE__, {:assign, instance}, 60_000)
  end

  def remove(instance) do
    GenServer.call(__MODULE__, {:remove, instance}, 60_000)
  end

  def get_pool(instance) do
    case instance.pool_id do
      nil -> nil
      pool_id -> Pool.with_instances(pool_id)
    end
  end

  def pools do
    Pool.active_pools()
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    Process.send_after(self(), :verify_pools, 5_000)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:verify_pools, state) do
    for pool <- Pool.active_pools() do
      case container_running?(pool.container) do
        true ->
          HealthMonitor.register(pool.name, pool.container, "openclaw")

        false ->
          Logger.warning("[pool_manager] pool=#{pool.name} container missing, restarting")
          restart_pool_container(pool)
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:assign, instance}, _from, state) do
    result = do_assign(instance)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:remove, instance}, _from, state) do
    result = do_remove(instance)
    {:reply, result, state}
  end

  # --- Internal ---

  defp do_assign(instance) do
    pool = Pool.pool_with_capacity() || create_pool()

    instance
    |> Ecto.Changeset.change(%{pool_id: pool.id})
    |> Repo.update!()

    pool = Pool.with_instances(pool.id)
    restart_pool_container(pool)

    Logger.info("[pool_manager] assigned instance=#{instance.name} to pool=#{pool.name} (#{length(pool.instances)}/#{pool.max_tenants})")

    {:ok, pool}
  rescue
    e ->
      Logger.error("[pool_manager] assign failed: #{inspect(e)}")
      {:error, e}
  end

  defp do_remove(instance) do
    pool_id = instance.pool_id

    instance
    |> Ecto.Changeset.change(%{pool_id: nil})
    |> Repo.update!()

    pool = Pool.with_instances(pool_id)

    if Enum.empty?(pool.instances) do
      stop_pool_container(pool)
      pool |> Ecto.Changeset.change(%{status: "stopped"}) |> Repo.update!()
      HealthMonitor.unregister(pool.name)
      Logger.info("[pool_manager] stopped empty pool=#{pool.name}")
    else
      restart_pool_container(pool)
      Logger.info("[pool_manager] removed instance=#{instance.name} from pool=#{pool.name} (#{length(pool.instances)}/#{pool.max_tenants})")
    end

    :ok
  rescue
    e ->
      Logger.error("[pool_manager] remove failed: #{inspect(e)}")
      {:error, e}
  end

  defp create_pool do
    name = Pool.next_name()
    port = Pool.next_port()
    container = "druzhok-pool-#{port - 18800 + 1}"

    %Pool{}
    |> Pool.changeset(%{name: name, container: container, port: port, status: "starting"})
    |> Repo.insert!()
  end

  defp restart_pool_container(pool) do
    stop_pool_container(pool)

    pool = Pool.with_instances(pool.id)
    instances = pool.instances |> Repo.preload([])

    data_root = pool_data_root(pool)
    File.mkdir_p!(data_root)

    config = PoolConfig.build(instances, port: pool.port)
    config_path = Path.join(data_root, "openclaw.json")
    File.write!(config_path, Jason.encode!(config, pretty: true))

    docker_args = build_docker_args(pool, instances)
    {_, 0} = System.cmd("docker", ["run" | docker_args])

    wait_for_health(pool)

    pool |> Ecto.Changeset.change(%{status: "running"}) |> Repo.update!()
    HealthMonitor.register(pool.name, pool.container, "openclaw")
  end

  defp stop_pool_container(pool) do
    System.cmd("docker", ["rm", "-f", pool.container], stderr_to_stdout: true)
    HealthMonitor.unregister(pool.name)
  end

  defp build_docker_args(pool, instances) do
    data_root = pool_data_root(pool)
    image = System.get_env("OPENCLAW_IMAGE") || "openclaw:slim"

    base_args = [
      "-d",
      "--name", pool.container,
      "--network", "host",
      "--restart", "unless-stopped",
      "-v", "#{data_root}:/data",
      "-v", "/var/run/docker.sock:/var/run/docker.sock",
      "-e", "OPENCLAW_CONFIG_PATH=/data/openclaw.json",
      "-e", "OPENCLAW_STATE_DIR=/data/state",
      "-e", "NODE_OPTIONS=--max-old-space-size=512",
      "-e", "NODE_ENV=production"
    ]

    workspace_mounts =
      Enum.flat_map(instances, fn inst ->
        host_workspace = inst.workspace
        container_workspace = "/data/workspaces/#{inst.name}"
        ["-v", "#{host_workspace}:#{container_workspace}"]
      end)

    command = ["node", "openclaw.mjs", "gateway", "--allow-unconfigured", "--bind", "lan"]

    base_args ++ workspace_mounts ++ [image | command]
  end

  defp wait_for_health(pool) do
    url = "http://127.0.0.1:#{pool.port}/healthz"

    Enum.reduce_while(1..@health_retries, nil, fn i, _ ->
      Process.sleep(1_000)

      case Finch.build(:get, url) |> Finch.request(Druzhok.LocalFinch) do
        {:ok, %{status: 200}} ->
          Logger.info("[pool_manager] pool=#{pool.name} health verified")
          {:halt, :ok}

        _ ->
          if i == @health_retries do
            Logger.error("[pool_manager] pool=#{pool.name} health check failed after #{@health_retries}s")
            {:halt, :timeout}
          else
            {:cont, nil}
          end
      end
    end)
  end

  defp container_running?(container) do
    case System.cmd("docker", ["inspect", "--format", "{{.State.Running}}", container], stderr_to_stdout: true) do
      {"true\n", 0} -> true
      _ -> false
    end
  end

  defp pool_data_root(pool) do
    data_root = System.get_env("DRUZHOK_DATA_ROOT") || "/home/igor/druzhok-data"
    Path.join([data_root, "pools", pool.name])
  end
end
```

- [ ] **Step 2: Verify compilation**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix compile
```

Expected: no errors.

- [ ] **Step 3: Commit**

```
feat: add PoolManager GenServer for multi-tenant OpenClaw
```

---

### Task 5: Runtime Behaviour — Add pooled?/0

**Files:**
- Modify: `apps/druzhok/lib/druzhok/runtime.ex`
- Modify: `apps/druzhok/lib/druzhok/runtime/zero_claw.ex`
- Modify: `apps/druzhok/lib/druzhok/runtime/pico_claw.ex`
- Modify: `apps/druzhok/lib/druzhok/runtime/null_claw.ex`
- Modify: `apps/druzhok/lib/druzhok/runtime/open_claw.ex`

- [ ] **Step 1: Add callback to behaviour**

In `apps/druzhok/lib/druzhok/runtime.ex`, add after the existing callbacks:

```elixir
@callback pooled?() :: boolean()
```

And add a default implementation in the `__using__` macro or at the module level. If there's no `__using__` macro, add a helper function:

```elixir
def pooled?(runtime_module) do
  runtime_module.pooled?()
end
```

- [ ] **Step 2: Add pooled?/0 to all solo runtimes**

In each of `zero_claw.ex`, `pico_claw.ex`, `null_claw.ex`, add:

```elixir
@impl true
def pooled?, do: false
```

- [ ] **Step 3: Add pooled?/0 to OpenClaw**

In `open_claw.ex`, add:

```elixir
@impl true
def pooled?, do: true
```

- [ ] **Step 4: Verify compilation**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix compile
```

Expected: no errors, no warnings about missing callback implementations.

- [ ] **Step 5: Commit**

```
feat: add pooled?/0 callback to Runtime behaviour
```

---

### Task 6: BotManager — Branch on pooled?/0

**Files:**
- Modify: `apps/druzhok/lib/druzhok/bot_manager.ex`

- [ ] **Step 1: Modify start/1**

Find the `start/1` function. After the line that resolves the runtime module, add a branch:

```elixir
def start(name) do
  instance = Repo.get_by!(Instance, name: name) |> Repo.preload(:budget)
  runtime = Runtime.get(instance.bot_runtime)

  if runtime.pooled?() do
    start_pooled(instance, runtime)
  else
    start_solo(instance, runtime)
  end
end

defp start_pooled(instance, _runtime) do
  {:ok, pool} = Druzhok.PoolManager.assign(instance)

  Task.start(fn ->
    Druzhok.LogWatcher.start_link(
      name: instance.name,
      container: pool.container,
      runtime: Druzhok.Runtime.OpenClaw,
      bot_token: instance.telegram_token,
      language: instance.language || "ru",
      reject_message: instance.reject_message
    )
  end)

  instance |> Ecto.Changeset.change(%{active: true}) |> Repo.update!()
  Druzhok.Events.broadcast(instance.name, %{type: :started, bot_runtime: instance.bot_runtime, pool: pool.name})
  :ok
end

defp start_solo(instance, runtime) do
  # ... existing start logic moved here, unchanged ...
end
```

- [ ] **Step 2: Modify stop/1**

```elixir
def stop(name) do
  instance = Repo.get_by!(Instance, name: name)
  runtime = Runtime.get(instance.bot_runtime)

  Druzhok.LogWatcher.stop(name)

  if runtime.pooled?() do
    Druzhok.PoolManager.remove(instance)
  else
    stop_container(name)
    HealthMonitor.unregister(name)
  end

  instance |> Ecto.Changeset.change(%{active: false}) |> Repo.update!()
  :ok
end
```

- [ ] **Step 3: Verify compilation**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix compile
```

Expected: no errors.

- [ ] **Step 4: Commit**

```
feat: branch BotManager start/stop on pooled? runtime
```

---

### Task 7: Add PoolManager to Supervision Tree

**Files:**
- Modify: `apps/druzhok/lib/druzhok/application.ex`

- [ ] **Step 1: Add PoolManager to children list**

In `application.ex`, add `Druzhok.PoolManager` to the children list, after `Druzhok.HealthMonitor`:

```elixir
children = [
  Druzhok.Repo,
  {Registry, keys: :unique, name: Druzhok.Registry},
  {DynamicSupervisor, name: Druzhok.InstanceDynSup, strategy: :one_for_one},
  {Finch, finch_config},
  {Finch, name: Druzhok.LocalFinch},
  Druzhok.HealthMonitor,
  Druzhok.PoolManager
]
```

- [ ] **Step 2: Verify it starts**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix compile
```

Expected: no errors.

- [ ] **Step 3: Commit**

```
feat: add PoolManager to application supervision tree
```

---

### Task 8: LogWatcher — Support shared container name

**Files:**
- Modify: `apps/druzhok/lib/druzhok/log_watcher.ex`

- [ ] **Step 1: Add container option to start_link**

The LogWatcher currently derives the container name from the instance name (`druzhok-bot-{name}`). For pooled instances, the container is the pool container. Add a `:container` option:

In `init/1`, change the container name resolution:

```elixir
def init(opts) do
  instance_name = Keyword.fetch!(opts, :name)
  runtime = Keyword.fetch!(opts, :runtime)
  bot_token = Keyword.fetch!(opts, :bot_token)
  language = Keyword.get(opts, :language, "ru")
  reject_message = Keyword.get(opts, :reject_message)
  container = Keyword.get(opts, :container, "druzhok-bot-#{instance_name}")

  # Use container instead of deriving from instance_name
  port = open_docker_logs(container)
  # ... rest unchanged, but store container in state
end
```

Replace the hardcoded `"druzhok-bot-#{instance_name}"` with the `container` variable wherever it appears in the module (the `open_docker_logs` call and reconnect logic).

- [ ] **Step 2: Verify compilation**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix compile
```

Expected: no errors.

- [ ] **Step 3: Commit**

```
feat: LogWatcher accepts explicit container name for pool support
```

---

### Task 9: Dashboard — Pool Sidebar Hierarchy

**Files:**
- Modify: `apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex`

- [ ] **Step 1: Load pools in mount/3**

In the `mount/3` function, add pools to assigns:

```elixir
pools = Druzhok.PoolManager.pools()
```

Add to socket assigns:

```elixir
|> assign(:pools, pools)
```

- [ ] **Step 2: Modify sidebar template**

Replace the flat instance list in the sidebar with a grouped view. In the `render/1` function or the corresponding template, replace the instance list with:

```heex
<div class="sidebar">
  <h3>Pools</h3>
  <%= for pool <- @pools do %>
    <div class="pool-group">
      <div class="pool-header" phx-click="select_pool" phx-value-pool={pool.name}>
        <%= pool.name %> (<%= length(pool.instances) %>/<%= pool.max_tenants %>)
        <span class={"status-dot #{pool.status}"}></span>
      </div>
      <div class="pool-instances">
        <%= for inst <- pool.instances do %>
          <div class={"instance-item #{if @selected == inst.name, do: "selected"}"} phx-click="select" phx-value-name={inst.name}>
            <%= inst.name %>
          </div>
        <% end %>
      </div>
    </div>
  <% end %>

  <!-- Solo instances (non-pooled) -->
  <%= for inst <- @instances, is_nil(inst.pool_id) do %>
    <div class={"instance-item #{if @selected == inst.name, do: "selected"}"} phx-click="select" phx-value-name={inst.name}>
      <%= inst.name %> (<%= inst.bot_runtime %>)
    </div>
  <% end %>
</div>
```

- [ ] **Step 3: Add select_pool event handler**

```elixir
def handle_event("select_pool", %{"pool" => pool_name}, socket) do
  pool = Enum.find(socket.assigns.pools, &(&1.name == pool_name))
  {:noreply, assign(socket, :selected_pool, pool)}
end
```

- [ ] **Step 4: Refresh pools on events**

In the `handle_info` for PubSub events, refresh pool data:

```elixir
pools = Druzhok.PoolManager.pools()
{:noreply, assign(socket, :pools, pools)}
```

- [ ] **Step 5: Verify compilation**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix compile
```

Expected: no errors.

- [ ] **Step 6: Commit**

```
feat: dashboard sidebar shows pool hierarchy with instance grouping
```

---

### Task 10: Integration Test — Full Pool Lifecycle

**Files:**
- Create: `apps/druzhok/test/druzhok/pool_manager_test.exs`

- [ ] **Step 1: Write integration test**

```elixir
defmodule Druzhok.PoolManagerTest do
  use Druzhok.DataCase, async: false

  alias Druzhok.{Pool, Instance, PoolConfig, Repo}

  describe "PoolConfig.build/2" do
    test "builds valid config with correct structure" do
      instances = [
        %{name: "test1", model: "gpt-4o", on_demand_model: nil, tenant_key: "dk-test1", telegram_token: "111:AAA", workspace: "/tmp/test1"},
        %{name: "test2", model: "gpt-4o", on_demand_model: "claude-opus", tenant_key: "dk-test2", telegram_token: "222:BBB", workspace: "/tmp/test2"}
      ]

      config = PoolConfig.build(instances, port: 18800)

      # Verify all top-level keys present
      assert Map.has_key?(config, "gateway")
      assert Map.has_key?(config, "agents")
      assert Map.has_key?(config, "channels")
      assert Map.has_key?(config, "bindings")
      assert Map.has_key?(config, "models")
      assert Map.has_key?(config, "session")

      # Verify JSON serializable
      assert {:ok, _} = Jason.encode(config)
    end

    test "on_demand_model adds smart model to provider" do
      instances = [
        %{name: "test", model: "gpt-4o", on_demand_model: "claude-opus", tenant_key: "dk-test", telegram_token: "111:A", workspace: "/tmp/test"}
      ]

      config = PoolConfig.build(instances, port: 18800)
      models = config["models"]["providers"]["tenant-test"]["models"]

      assert length(models) == 2
      assert Enum.any?(models, &(&1["name"] == "default" && &1["id"] == "gpt-4o"))
      assert Enum.any?(models, &(&1["name"] == "smart" && &1["id"] == "claude-opus"))
    end
  end

  describe "Pool schema" do
    test "next_port returns base when no pools exist" do
      assert Pool.next_port() == 18800
    end

    test "next_port increments from max" do
      Repo.insert!(%Pool{name: "test-pool", container: "test-container", port: 18800, status: "running"})
      assert Pool.next_port() == 18801
    end

    test "pool_with_capacity finds pool with room" do
      pool = Repo.insert!(%Pool{name: "test-pool", container: "test-container", port: 18800, max_tenants: 10, status: "running"})
      assert found = Pool.pool_with_capacity()
      assert found.id == pool.id
    end
  end
end
```

- [ ] **Step 2: Run tests**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix test apps/druzhok/test/druzhok/pool_manager_test.exs apps/druzhok/test/druzhok/pool_config_test.exs
```

Expected: all tests pass.

- [ ] **Step 3: Run full test suite**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix test
```

Expected: no regressions. Existing tests still pass.

- [ ] **Step 4: Commit**

```
feat: add pool manager and config generation tests
```

---

### Task 11: Clean Up Docker Test Images

**Files:** None (cleanup)

- [ ] **Step 1: Remove test images from research**

```bash
docker rmi openclaw:slim 2>/dev/null; echo "done"
```

- [ ] **Step 2: Verify remaining images**

```bash
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"
```

Expected: no openclaw:slim or openclaw:bun images remaining.

- [ ] **Step 3: Commit all remaining changes**

```
chore: clean up Docker test artifacts from pool research
```
