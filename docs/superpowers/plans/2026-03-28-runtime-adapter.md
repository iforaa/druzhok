# Runtime Adapter System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace hardcoded runtime branches with a pluggable behaviour so adding a new bot runtime = one new module.

**Architecture:** Create `Druzhok.Runtime` behaviour with callbacks for env vars, workspace files, Docker image, health checks. Implement for ZeroClaw and PicoClaw. Delete `BotConfig`, update `BotManager` and `HealthMonitor` to use adapters. Update dashboard to generate dropdowns from registry.

**Tech Stack:** Elixir behaviours, existing Phoenix LiveView dashboard

---

## File Structure

```
Create: apps/druzhok/lib/druzhok/runtime.ex           — behaviour + registry
Create: apps/druzhok/lib/druzhok/runtime/zero_claw.ex  — ZeroClaw adapter
Create: apps/druzhok/lib/druzhok/runtime/pico_claw.ex  — PicoClaw adapter
Delete: apps/druzhok/lib/druzhok/bot_config.ex          — replaced by runtime adapters
Modify: apps/druzhok/lib/druzhok/bot_manager.ex         — use Runtime instead of BotConfig
Modify: apps/druzhok/lib/druzhok/health_monitor.ex      — use Runtime for health checks
Modify: dashboard_live.ex                                — dynamic runtime dropdown
```

---

### Task 1: Create Runtime Behaviour and Registry

**Files:**
- Create: `apps/druzhok/lib/druzhok/runtime.ex`

- [ ] **Step 1: Create the behaviour and registry module**

```elixir
defmodule Druzhok.Runtime do
  @moduledoc """
  Behaviour for bot runtime adapters. Each supported runtime (ZeroClaw, PicoClaw, etc.)
  implements this behaviour. Adding a new runtime = one new module + one registry entry.
  """

  @type instance :: map()

  @callback env_vars(instance) :: %{String.t() => String.t()}
  @callback workspace_files(instance) :: [{path :: String.t(), content :: String.t()}]
  @callback docker_image() :: String.t()
  @callback gateway_command() :: String.t()
  @callback health_path() :: String.t()
  @callback health_port() :: integer()
  @callback supports_feature?(atom()) :: boolean()

  @runtimes %{
    "zeroclaw" => Druzhok.Runtime.ZeroClaw,
    "picoclaw" => Druzhok.Runtime.PicoClaw,
  }

  def get(name) do
    Map.fetch!(@runtimes, to_string(name))
  end

  def get(name, default) do
    Map.get(@runtimes, to_string(name), default)
  end

  def list, do: @runtimes
  def names, do: Map.keys(@runtimes)

  def base_env(instance) do
    proxy_host = System.get_env("LLM_PROXY_HOST") || "host.docker.internal"
    proxy_port = System.get_env("LLM_PROXY_PORT") || "4000"

    %{
      "OPENAI_BASE_URL" => "http://#{proxy_host}:#{proxy_port}/v1",
      "OPENAI_API_KEY" => Map.get(instance, :tenant_key, "") || "",
      "TZ" => Map.get(instance, :timezone, "UTC") || "UTC",
    }
  end
end
```

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix compile 2>&1 | grep error`
Expected: No errors (warnings about missing adapter modules are OK at this point)

- [ ] **Step 3: Commit**

```
feat: add Runtime behaviour and registry
```

---

### Task 2: Create ZeroClaw Adapter

**Files:**
- Create: `apps/druzhok/lib/druzhok/runtime/zero_claw.ex`

- [ ] **Step 1: Create the adapter**

```elixir
defmodule Druzhok.Runtime.ZeroClaw do
  @behaviour Druzhok.Runtime

  @impl true
  def env_vars(instance) do
    env = %{
      "ZEROCLAW_AGENT_MODEL" => Map.get(instance, :model, "default") || "default",
      "ZEROCLAW_PROVIDER_TYPE" => "compatible",
    }

    token = Map.get(instance, :telegram_token)
    if token do
      Map.merge(env, %{
        "ZEROCLAW_CHANNELS_TELEGRAM_ENABLED" => "true",
        "ZEROCLAW_CHANNELS_TELEGRAM_TOKEN" => token,
      })
    else
      env
    end
  end

  @impl true
  def workspace_files(instance) do
    token = Map.get(instance, :telegram_token)
    allowed = Map.get(instance, :allowed_users, []) || []

    if token do
      toml = """
      [channels.telegram]
      bot_token = "#{token}"
      allowed_users = #{inspect(allowed)}
      """
      [{"config.toml", toml}]
    else
      []
    end
  end

  @impl true
  def docker_image, do: System.get_env("ZEROCLAW_IMAGE") || "zeroclaw:latest"

  @impl true
  def gateway_command, do: "gateway"

  @impl true
  def health_path, do: "/api/health"

  @impl true
  def health_port, do: 18790

  @impl true
  def supports_feature?(:pairing), do: true
  def supports_feature?(:hot_reload_config), do: true
  def supports_feature?(_), do: false
end
```

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix compile 2>&1 | grep error`
Expected: No errors

- [ ] **Step 3: Commit**

```
feat: add ZeroClaw runtime adapter
```

---

### Task 3: Create PicoClaw Adapter

**Files:**
- Create: `apps/druzhok/lib/druzhok/runtime/pico_claw.ex`

- [ ] **Step 1: Create the adapter**

```elixir
defmodule Druzhok.Runtime.PicoClaw do
  @behaviour Druzhok.Runtime

  @impl true
  def env_vars(instance) do
    env = %{
      "PICOCLAW_AGENTS_DEFAULTS_MODEL_NAME" => Map.get(instance, :model, "default") || "default",
    }

    token = Map.get(instance, :telegram_token)
    if token do
      allowed = Map.get(instance, :allowed_users, []) || []
      Map.merge(env, %{
        "PICOCLAW_CHANNELS_TELEGRAM_ENABLED" => "true",
        "PICOCLAW_CHANNELS_TELEGRAM_TOKEN" => token,
        "PICOCLAW_CHANNELS_TELEGRAM_ALLOW_FROM" => Jason.encode!(allowed),
      })
    else
      env
    end
  end

  @impl true
  def workspace_files(_instance), do: []

  @impl true
  def docker_image, do: System.get_env("PICOCLAW_IMAGE") || "picoclaw:latest"

  @impl true
  def gateway_command, do: "gateway"

  @impl true
  def health_path, do: "/health"

  @impl true
  def health_port, do: 18790

  @impl true
  def supports_feature?(:pairing), do: false
  def supports_feature?(_), do: false
end
```

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix compile 2>&1 | grep error`
Expected: No errors

- [ ] **Step 3: Commit**

```
feat: add PicoClaw runtime adapter
```

---

### Task 4: Update BotManager to Use Runtime Adapters

**Files:**
- Modify: `apps/druzhok/lib/druzhok/bot_manager.ex`
- Delete: `apps/druzhok/lib/druzhok/bot_config.ex`

- [ ] **Step 1: Update BotManager.start/1 to use Runtime**

Replace the `start/1` function. Change lines 52-70 from:

```elixir
      instance ->
        env = BotConfig.build(instance)
        image = BotConfig.docker_image(instance)

        case start_container(name, image, env, instance.workspace) do
```

To:

```elixir
      instance ->
        runtime = Druzhok.Runtime.get(instance.bot_runtime, Druzhok.Runtime.ZeroClaw)
        env = Druzhok.Runtime.base_env(instance) |> Map.merge(runtime.env_vars(instance))
        image = runtime.docker_image()
        command = runtime.gateway_command()

        # Write runtime-specific config files to workspace
        for {path, content} <- runtime.workspace_files(instance) do
          full_path = Path.join(instance.workspace, path)
          File.mkdir_p!(Path.dirname(full_path))
          File.write!(full_path, content)
        end

        case start_container(name, image, env, instance.workspace, command) do
```

- [ ] **Step 2: Update start_container to accept command parameter**

Replace the `start_container/4` function (lines 105-118) with:

```elixir
  defp start_container(name, image, env, workspace, command) do
    env_args = Enum.flat_map(env, fn {k, v} -> ["-e", "#{k}=#{v}"] end)

    args = ["run", "-d",
      "--name", container_name(name),
      "--network", "host",
      "--restart", "unless-stopped",
      "-v", "#{workspace}:/data",
    ] ++ env_args ++ [image, command]

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {container_id, 0} -> {:ok, String.trim(container_id)}
      {error, _} -> {:error, String.trim(error)}
    end
  end
```

- [ ] **Step 3: Remove BotConfig alias from BotManager**

Change line 7 from:
```elixir
  alias Druzhok.{Instance, InstanceManager, BotConfig, TokenPool, Budget, Repo}
```
To:
```elixir
  alias Druzhok.{Instance, InstanceManager, TokenPool, Budget, Repo}
```

- [ ] **Step 4: Delete BotConfig**

```bash
rm apps/druzhok/lib/druzhok/bot_config.ex
```

- [ ] **Step 5: Verify it compiles**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix compile 2>&1 | grep error`
Expected: No errors. No references to BotConfig should remain.

- [ ] **Step 6: Commit**

```
refactor: BotManager uses Runtime adapters, delete BotConfig
```

---

### Task 5: Update HealthMonitor to Use Runtime

**Files:**
- Modify: `apps/druzhok/lib/druzhok/health_monitor.ex`

- [ ] **Step 1: Store runtime name in registered bot info**

Update `register/2` to `register/3` — add `bot_runtime` parameter.

Change line 16-17:
```elixir
  def register(name, container_id) do
    GenServer.cast(__MODULE__, {:register, name, container_id})
  end
```
To:
```elixir
  def register(name, container_id, bot_runtime \\ "zeroclaw") do
    GenServer.cast(__MODULE__, {:register, name, container_id, bot_runtime})
  end
```

Change handle_cast (line 35-37):
```elixir
  def handle_cast({:register, name, container_id}, state) do
    bots = Map.put(state.bots, name, %{container_id: container_id, failures: 0, status: :healthy})
```
To:
```elixir
  def handle_cast({:register, name, container_id, bot_runtime}, state) do
    bots = Map.put(state.bots, name, %{container_id: container_id, bot_runtime: bot_runtime, failures: 0, status: :healthy})
```

- [ ] **Step 2: Update BotManager to pass runtime to register**

In `apps/druzhok/lib/druzhok/bot_manager.ex`, in `start/1`, change:
```elixir
            Druzhok.HealthMonitor.register(name, container_id)
```
To:
```elixir
            Druzhok.HealthMonitor.register(name, container_id, instance.bot_runtime || "zeroclaw")
```

- [ ] **Step 3: Verify it compiles**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix compile 2>&1 | grep error`
Expected: No errors

- [ ] **Step 4: Commit**

```
feat: HealthMonitor tracks bot_runtime per instance
```

---

### Task 6: Update Dashboard to Use Runtime Registry

**Files:**
- Modify: `apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex`

- [ ] **Step 1: Replace hardcoded runtime options in create form (line 410-412)**

Replace:
```heex
            <select name="bot_runtime" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-gray-900">
              <option value="zeroclaw">ZeroClaw (Rust, lightweight)</option>
              <option value="picoclaw">PicoClaw (Go, 30+ channels)</option>
            </select>
```

With:
```heex
            <select name="bot_runtime" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-gray-900">
              <option :for={name <- Druzhok.Runtime.names()} value={name} selected={name == "zeroclaw"}><%= name %></option>
            </select>
```

- [ ] **Step 2: Replace hardcoded runtime options in settings tab (lines 530-532)**

Replace:
```heex
                    <select name="bot_runtime" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm">
                      <option value="zeroclaw" selected={selected_field(@instances, @selected, :bot_runtime) != "picoclaw"}>ZeroClaw (Rust)</option>
                      <option value="picoclaw" selected={selected_field(@instances, @selected, :bot_runtime) == "picoclaw"}>PicoClaw (Go)</option>
                    </select>
```

With:
```heex
                    <select name="bot_runtime" class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm">
                      <option :for={name <- Druzhok.Runtime.names()} value={name} selected={name == (selected_field(@instances, @selected, :bot_runtime) || "zeroclaw")}><%= name %></option>
                    </select>
```

- [ ] **Step 3: Verify it compiles**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix compile 2>&1 | grep error`
Expected: No errors

- [ ] **Step 4: Commit**

```
refactor: dashboard runtime dropdown driven by Runtime registry
```

---

### Task 7: Verify End-to-End

- [ ] **Step 1: Verify no references to BotConfig remain**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && grep -r "BotConfig" apps/druzhok/lib/ apps/druzhok_web/lib/
```

Expected: No output

- [ ] **Step 2: Verify clean compilation**

```bash
mix compile --force 2>&1
```

Expected: Only pre-existing Bcrypt warnings, no errors

- [ ] **Step 3: Commit spec and plan**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add docs/superpowers/specs/2026-03-28-runtime-adapter-design.md docs/superpowers/plans/2026-03-28-runtime-adapter.md
git commit -m "docs: runtime adapter design spec and plan"
```
