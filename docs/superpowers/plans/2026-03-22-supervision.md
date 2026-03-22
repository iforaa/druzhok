# Instance Supervision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ad-hoc process management with OTP supervision trees so instances auto-recover from crashes.

**Architecture:** Each instance gets its own Supervisor (one_for_one) under a DynamicSupervisor. Processes find each other via Registry instead of stored PIDs. An InstanceWatcher monitors Supervisors and marks crashed instances inactive in DB.

**Tech Stack:** Elixir OTP (Supervisor, DynamicSupervisor, Registry, GenServer), Ecto/SQLite

**Spec:** `docs/superpowers/specs/2026-03-22-supervision-design.md`

---

### Task 1: InstanceWatcher GenServer

**Files:**
- Create: `v3/apps/druzhok/lib/druzhok/instance_watcher.ex`
- Test: `v3/apps/druzhok/test/druzhok/instance_watcher_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
# v3/apps/druzhok/test/druzhok/instance_watcher_test.exs
defmodule Druzhok.InstanceWatcherTest do
  use ExUnit.Case, async: false

  alias Druzhok.InstanceWatcher

  setup do
    start_supervised!(InstanceWatcher)
    :ok
  end

  test "receives DOWN when watched process dies" do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    InstanceWatcher.watch("test-instance", pid)
    Process.exit(pid, :kill)
    Process.sleep(50)
    # Watcher should have processed the DOWN — no crash
    assert Process.alive?(Process.whereis(InstanceWatcher))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd v3 && mix test apps/druzhok/test/druzhok/instance_watcher_test.exs --trace`
Expected: FAIL — module `Druzhok.InstanceWatcher` not found

- [ ] **Step 3: Implement InstanceWatcher**

```elixir
# v3/apps/druzhok/lib/druzhok/instance_watcher.ex
defmodule Druzhok.InstanceWatcher do
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def watch(instance_name, sup_pid) do
    GenServer.cast(__MODULE__, {:watch, instance_name, sup_pid})
  end

  def init(state), do: {:ok, state}

  def handle_cast({:watch, name, pid}, state) do
    Process.monitor(pid)
    {:noreply, Map.put(state, pid, name)}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Map.pop(state, pid) do
      {nil, state} ->
        {:noreply, state}

      {name, state} ->
        Logger.error("Instance #{name} supervisor crashed: #{inspect(reason)}")
        Druzhok.Events.broadcast(name, %{type: :instance_crashed, reason: inspect(reason)})

        case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
          nil -> :ok
          inst -> Druzhok.Repo.update(Druzhok.Instance.changeset(inst, %{active: false}))
        end

        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd v3 && mix test apps/druzhok/test/druzhok/instance_watcher_test.exs --trace`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add v3/apps/druzhok/lib/druzhok/instance_watcher.ex v3/apps/druzhok/test/druzhok/instance_watcher_test.exs
git commit -m "add InstanceWatcher for crash detection"
```

---

### Task 2: Instance.Sup — per-instance Supervisor

**Files:**
- Create: `v3/apps/druzhok/lib/druzhok/instance/sup.ex`
- Test: `v3/apps/druzhok/test/druzhok/instance/sup_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
# v3/apps/druzhok/test/druzhok/instance/sup_test.exs
defmodule Druzhok.Instance.SupTest do
  use ExUnit.Case, async: false

  setup do
    # Registry should be running from the application.
    # If not (isolated test), start it:
    # start_supervised!({Registry, keys: :unique, name: Druzhok.Registry})
    name = "test-sup-#{:rand.uniform(100000)}"
    workspace = Path.join(System.tmp_dir!(), "druzhok_sup_test_#{name}")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(workspace, "memory"))
    # Write minimal AGENTS.md so workspace loader works
    File.write!(Path.join(workspace, "AGENTS.md"), "You are a test bot.")

    on_exit(fn -> File.rm_rf!(workspace) end)

    config = %{
      name: name,
      token: "fake-token-#{name}",
      model: "test-model",
      workspace: workspace,
      api_url: "http://localhost:9999",
      api_key: "fake-key",
      heartbeat_interval: 0,
    }

    %{config: config, name: name}
  end

  test "starts all 3 children and registers them", %{config: config, name: name} do
    {:ok, sup_pid} = Druzhok.Instance.Sup.start_link(config)

    # Give children time to register
    Process.sleep(200)

    assert [{_, _}] = Registry.lookup(Druzhok.Registry, {name, :telegram})
    assert [{_, _}] = Registry.lookup(Druzhok.Registry, {name, :session})
    assert [{_, _}] = Registry.lookup(Druzhok.Registry, {name, :scheduler})

    Supervisor.stop(sup_pid)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd v3 && mix test apps/druzhok/test/druzhok/instance/sup_test.exs --trace`
Expected: FAIL — module `Druzhok.Instance.Sup` not found

- [ ] **Step 3: Implement Instance.Sup**

```elixir
# v3/apps/druzhok/lib/druzhok/instance/sup.ex
defmodule Druzhok.Instance.Sup do
  use Supervisor

  def start_link(config) do
    name = {:via, Registry, {Druzhok.Registry, {config.name, :sup}}}
    Supervisor.start_link(__MODULE__, config, name: name)
  end

  def init(config) do
    name = config.name

    on_delta = fn chunk ->
      case Registry.lookup(Druzhok.Registry, {name, :telegram}) do
        [{pid, _}] -> send(pid, {:pi_delta, chunk})
        [] -> :ok
      end
    end

    on_event = fn event ->
      Druzhok.Events.broadcast(name, event)
    end

    send_file_fn = fn file_path, caption ->
      case Registry.lookup(Druzhok.Registry, {name, :telegram}) do
        [{pid, _}] ->
          chat_id = GenServer.call(pid, :get_chat_id, 5_000)
          if chat_id do
            Druzhok.Telegram.API.send_document(config.token, chat_id, file_path, %{caption: caption})
          else
            {:error, "No active chat"}
          end
        [] -> {:error, "Telegram not available"}
      end
    end

    children = [
      {Druzhok.Agent.Telegram, %{
        token: config.token,
        session_pid: nil,
        instance_name: name,
        registry_name: {:via, Registry, {Druzhok.Registry, {name, :telegram}}},
      }},
      {PiCore.Session, %{
        name: {:via, Registry, {Druzhok.Registry, {name, :session}}},
        workspace: config.workspace,
        model: config.model,
        api_url: config.api_url,
        api_key: config.api_key,
        instance_name: name,
        on_delta: on_delta,
        on_event: on_event,
        extra_tool_context: %{send_file_fn: send_file_fn},
      }},
      {Druzhok.Scheduler, %{
        instance_name: name,
        workspace: config.workspace,
        heartbeat_interval: config.heartbeat_interval,
        registry_name: {:via, Registry, {Druzhok.Registry, {name, :scheduler}}},
      }},
    ]

    # Wire Telegram → Session after children start
    Task.start(fn ->
      Process.sleep(100)
      case Registry.lookup(Druzhok.Registry, {name, :session}) do
        [{session_pid, _}] ->
          case Registry.lookup(Druzhok.Registry, {name, :telegram}) do
            [{telegram_pid, _}] -> GenServer.cast(telegram_pid, {:set_session, session_pid})
            _ -> :ok
          end
        _ -> :ok
      end
    end)

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 60)
  end
end
```

- [ ] **Step 4: Update Telegram to accept `registry_name` for registration**

In `v3/apps/druzhok/lib/druzhok/agent/telegram.ex`, change `start_link`:

```elixir
def start_link(opts) do
  name = opts[:registry_name]
  if name do
    GenServer.start_link(__MODULE__, opts, name: name)
  else
    GenServer.start_link(__MODULE__, opts)
  end
end
```

- [ ] **Step 5: Update PiCore.Session to accept `name` for registration**

In `v3/apps/pi_core/lib/pi_core/session.ex`, change `start_link`:

```elixir
def start_link(opts) do
  gen_opts = case opts[:name] do
    nil -> []
    name -> [name: name]
  end
  GenServer.start_link(__MODULE__, opts, gen_opts)
end
```

- [ ] **Step 6: Update Scheduler to accept `registry_name` for registration**

In `v3/apps/druzhok/lib/druzhok/scheduler.ex`, change `start_link`:

```elixir
def start_link(opts) do
  name = opts[:registry_name]
  if name do
    GenServer.start_link(__MODULE__, opts, name: name)
  else
    GenServer.start_link(__MODULE__, opts)
  end
end
```

- [ ] **Step 7: Run test to verify it passes**

Run: `cd v3 && mix test apps/druzhok/test/druzhok/instance/sup_test.exs --trace`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add v3/apps/druzhok/lib/druzhok/instance/sup.ex v3/apps/druzhok/test/druzhok/instance/sup_test.exs v3/apps/druzhok/lib/druzhok/agent/telegram.ex v3/apps/pi_core/lib/pi_core/session.ex v3/apps/druzhok/lib/druzhok/scheduler.ex
git commit -m "add per-instance Supervisor with Registry registration"
```

---

### Task 3: Telegram uses Registry for Session dispatch

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/agent/telegram.ex`

- [ ] **Step 1: Replace all `PiCore.Session.prompt(state.session_pid, ...)` calls with Registry lookup**

Add a `dispatch_prompt` helper:

```elixir
defp dispatch_prompt(text, state) do
  case Registry.lookup(Druzhok.Registry, {state.instance_name, :session}) do
    [{pid, _}] -> PiCore.Session.prompt(pid, text)
    [] -> :ok
  end
end
```

Replace in `handle_update`:
- `PiCore.Session.prompt(state.session_pid, prompt)` → `dispatch_prompt(prompt, state)`
- `PiCore.Session.reset(state.session_pid)` → Registry lookup + reset
- `PiCore.Session.abort(state.session_pid)` → Registry lookup + abort

Telegram can keep `session_pid` in struct for the initial `set_session` wiring, but all runtime dispatch goes through Registry.

- [ ] **Step 2: Run full test suite**

Run: `cd v3 && mix test`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add v3/apps/druzhok/lib/druzhok/agent/telegram.ex
git commit -m "telegram: dispatch to session via Registry lookup"
```

---

### Task 4: Session uses Registry for caller (deliver_last_assistant)

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/session.ex`

- [ ] **Step 1: Update `deliver_last_assistant` to use Registry when `instance_name` is set**

```elixir
defp deliver_last_assistant(new_messages, ref, state) do
  case Enum.find(Enum.reverse(new_messages), &(&1.role == "assistant")) do
    nil -> :ok
    msg ->
      pid = if state.instance_name do
        case Registry.lookup(Druzhok.Registry, {state.instance_name, :telegram}) do
          [{p, _}] -> p
          [] -> nil
        end
      else
        state.caller
      end

      if pid, do: send(pid, {:pi_response, %{text: msg.content, prompt_id: ref}})
  end
end
```

This keeps backward compatibility — tests without `instance_name` still use `caller` PID.

- [ ] **Step 2: Same for error delivery in `handle_info({:DOWN, ...})`**

Update the error send to also use Registry lookup when `instance_name` is set.

- [ ] **Step 3: Run full test suite**

Run: `cd v3 && mix test`
Expected: All tests pass (pi_core tests use `caller` directly, druzhok uses Registry)

- [ ] **Step 4: Commit**

```bash
git add v3/apps/pi_core/lib/pi_core/session.ex
git commit -m "session: deliver responses via Registry when instance_name set"
```

---

### Task 5: Scheduler uses Registry for Session lookup

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/scheduler.ex`

- [ ] **Step 1: Replace `PiCore.Session.prompt(state.session_pid, ...)` with Registry lookup**

Add helper:
```elixir
defp lookup_session(state) do
  case Registry.lookup(Druzhok.Registry, {state.instance_name, :session}) do
    [{pid, _}] -> pid
    [] -> nil
  end
end
```

Use in heartbeat tick and reminder check:
```elixir
case lookup_session(state) do
  nil -> :ok
  pid -> PiCore.Session.prompt(pid, prompt)
end
```

Remove `session_pid` from Scheduler struct — it's no longer needed.

- [ ] **Step 2: Run full test suite**

Run: `cd v3 && mix test`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add v3/apps/druzhok/lib/druzhok/scheduler.ex
git commit -m "scheduler: lookup session via Registry"
```

---

### Task 6: Rewrite InstanceManager to use DynamicSupervisor

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/instance_manager.ex`
- Modify: `v3/apps/druzhok/lib/druzhok/application.ex`

- [ ] **Step 1: Update application.ex**

Replace children list:
```elixir
children = [
  Druzhok.Repo,
  {Registry, keys: :unique, name: Druzhok.Registry},
  {DynamicSupervisor, name: Druzhok.InstanceDynSup, strategy: :one_for_one},
  Druzhok.InstanceWatcher,
  Supervisor.child_spec({Task, fn -> restore_instances() end}, restart: :temporary),
]
```

- [ ] **Step 2: Rewrite InstanceManager**

Replace entire module — `create/2` uses `DynamicSupervisor.start_child`, `stop/1` uses `DynamicSupervisor.terminate_child`, `list/0` reads from DB + Registry, remove all Agent references.

Key functions:
```elixir
def create(name, opts) do
  config = %{name: name, token: opts.telegram_token, model: opts.model,
             workspace: opts.workspace, api_url: opts.api_url, api_key: opts.api_key,
             heartbeat_interval: opts[:heartbeat_interval] || 0}
  ensure_workspace(config.workspace)

  case DynamicSupervisor.start_child(Druzhok.InstanceDynSup, {Druzhok.Instance.Sup, config}) do
    {:ok, sup_pid} ->
      Druzhok.InstanceWatcher.watch(name, sup_pid)
      save_to_db(name, opts)
      {:ok, %{name: name, model: config.model}}
    {:error, {:already_started, _}} ->
      {:ok, %{name: name, model: config.model}}
    {:error, reason} ->
      {:error, reason}
  end
end

def stop(name) when is_binary(name) do
  # Find the Sup PID for this instance
  case find_sup_pid(name) do
    nil -> :ok
    sup_pid -> DynamicSupervisor.terminate_child(Druzhok.InstanceDynSup, sup_pid)
  end
  case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
    nil -> :ok
    inst -> Druzhok.Repo.update(Druzhok.Instance.changeset(inst, %{active: false}))
  end
  :ok
end

def list do
  import Ecto.Query
  Druzhok.Repo.all(from i in Druzhok.Instance, where: i.active == true)
  |> Enum.map(fn inst ->
    alive = Registry.lookup(Druzhok.Registry, {inst.name, :telegram}) != []
    %{name: inst.name, model: inst.model, heartbeat_interval: inst.heartbeat_interval, alive: alive}
  end)
end

defp find_sup_pid(name) do
  # Instance.Sup registers itself as {name, :sup} in Registry
  case Registry.lookup(Druzhok.Registry, {name, :sup}) do
    [{pid, _}] -> pid
    [] -> nil
  end
end

defp lookup(name, role) do
  case Registry.lookup(Druzhok.Registry, {name, role}) do
    [{pid, _}] -> pid
    [] -> nil
  end
end
```

- [ ] **Step 3: Update dashboard `list_instances` to call `InstanceManager.list/0`**

In `v3/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex`, replace:
```elixir
defp list_instances do
  Druzhok.InstanceManager.list()
end
```

Update `stop` event handler to pass name string instead of instance map:
```elixir
def handle_event("stop", %{"name" => name}, socket) do
  Druzhok.InstanceManager.stop(name)
  {:noreply, assign(socket, instances: list_instances(), selected: nil, events: [])}
end
```

Update `update_model` and `update_heartbeat` in InstanceManager to use Registry lookup:
```elixir
def update_model(name, model) do
  case lookup(name, :session) do
    nil -> :ok
    pid -> PiCore.Session.set_model(pid, model)
  end
  case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
    nil -> :ok
    inst -> Druzhok.Repo.update(Druzhok.Instance.changeset(inst, %{model: model}))
  end
  :ok
end

def update_heartbeat(name, minutes) do
  case lookup(name, :scheduler) do
    nil -> :ok
    pid -> Druzhok.Scheduler.set_heartbeat_interval(pid, minutes)
  end
  :ok
end
```

Update all dashboard helpers that used the old Agent-based `get_instance`:
- `list_instances/0` → calls `Druzhok.InstanceManager.list/0`
- `get_instance/1` → calls `Enum.find(list_instances(), &(&1.name == name))`
- `handle_event("stop", ...)` → `Druzhok.InstanceManager.stop(name)` (string, not map)
- `handle_event("select", ...)` → works with the new list format (maps with `:name`, `:model` etc.)
- `handle_params` — same, uses `get_instance_from/2` which still works
- Remove old `rescue` block from `list_instances` (no more Agent to crash)
- `instance_workspace/1` still works (takes name string)

- [ ] **Step 4: Run full test suite**

Run: `cd v3 && mix test`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
git add v3/apps/druzhok/lib/druzhok/application.ex v3/apps/druzhok/lib/druzhok/instance_manager.ex v3/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex
git commit -m "replace Agent registry with DynamicSupervisor + Registry"
```

---

### Task 7: Supervision integration tests

**Files:**
- Create: `v3/apps/druzhok/test/druzhok/supervision_test.exs`

- [ ] **Step 1: Write crash isolation tests**

```elixir
defmodule Druzhok.SupervisionTest do
  use ExUnit.Case, async: false

  setup do
    name = "sup-test-#{:rand.uniform(100000)}"
    workspace = Path.join(System.tmp_dir!(), "druzhok_suptest_#{name}")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "AGENTS.md"), "You are a test bot.")

    on_exit(fn ->
      # Stop instance if still running
      Druzhok.InstanceManager.stop(name)
      File.rm_rf!(workspace)
    end)

    {:ok, _} = Druzhok.InstanceManager.create(name, %{
      workspace: workspace, model: "test-model",
      api_url: "http://localhost:9999", api_key: "fake",
      telegram_token: "fake-token-#{name}",
    })

    Process.sleep(300)  # Let children register
    %{name: name}
  end

  test "telegram crash doesn't affect session", %{name: name} do
    [{tg_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :telegram})
    [{sess_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :session})

    Process.exit(tg_pid, :kill)
    Process.sleep(200)

    # Session still alive
    assert Process.alive?(sess_pid)
    # Telegram restarted with new PID
    [{new_tg_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :telegram})
    assert new_tg_pid != tg_pid
  end

  test "session crash doesn't affect telegram", %{name: name} do
    [{tg_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :telegram})
    [{sess_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :session})

    Process.exit(sess_pid, :kill)
    Process.sleep(200)

    assert Process.alive?(tg_pid)
    [{new_sess_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :session})
    assert new_sess_pid != sess_pid
  end

  test "create is idempotent", %{name: name} do
    result = Druzhok.InstanceManager.create(name, %{
      workspace: "/tmp/whatever", model: "test",
      api_url: "http://localhost:9999", api_key: "fake",
      telegram_token: "fake",
    })
    assert {:ok, _} = result
  end

  test "scheduler crash doesn't affect telegram or session", %{name: name} do
    [{tg_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :telegram})
    [{sess_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :session})
    [{sched_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :scheduler})

    Process.exit(sched_pid, :kill)
    Process.sleep(200)

    assert Process.alive?(tg_pid)
    assert Process.alive?(sess_pid)
    [{new_sched_pid, _}] = Registry.lookup(Druzhok.Registry, {name, :scheduler})
    assert new_sched_pid != sched_pid
  end

  test "stop terminates all processes", %{name: name} do
    Druzhok.InstanceManager.stop(name)
    Process.sleep(200)

    assert Registry.lookup(Druzhok.Registry, {name, :telegram}) == []
    assert Registry.lookup(Druzhok.Registry, {name, :session}) == []
    assert Registry.lookup(Druzhok.Registry, {name, :scheduler}) == []
  end

  test "max restarts stops instance" do
    # Create a fresh instance for this test (not using setup's)
    name = "crashtest-#{:rand.uniform(100000)}"
    workspace = Path.join(System.tmp_dir!(), "druzhok_crashtest_#{name}")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(workspace, "memory"))
    File.write!(Path.join(workspace, "AGENTS.md"), "test")

    {:ok, _} = Druzhok.InstanceManager.create(name, %{
      workspace: workspace, model: "test",
      api_url: "http://localhost:9999", api_key: "fake",
      telegram_token: "fake-#{name}",
    })
    Process.sleep(300)

    # Kill telegram 4 times rapidly (max_restarts: 3 in 60s → 4th kills sup)
    for _ <- 1..4 do
      case Registry.lookup(Druzhok.Registry, {name, :telegram}) do
        [{pid, _}] -> Process.exit(pid, :kill)
        [] -> :ok
      end
      Process.sleep(100)
    end

    Process.sleep(500)

    # All processes should be gone
    assert Registry.lookup(Druzhok.Registry, {name, :telegram}) == []
    assert Registry.lookup(Druzhok.Registry, {name, :session}) == []
    assert Registry.lookup(Druzhok.Registry, {name, :sup}) == []

    File.rm_rf!(workspace)
  end
end
```

- [ ] **Step 2: Run tests**

Run: `cd v3 && mix test apps/druzhok/test/druzhok/supervision_test.exs --trace`
Expected: All pass

- [ ] **Step 3: Run full test suite to verify nothing broken**

Run: `cd v3 && mix test`
Expected: All pass

- [ ] **Step 4: Commit**

```bash
git add v3/apps/druzhok/test/druzhok/supervision_test.exs
git commit -m "add supervision integration tests"
```

---

### Task 8: Manual smoke test

- [ ] **Step 1: Kill old server, start fresh**

```bash
# Kill beam, source env, start server
ps aux | grep beam | grep -v grep | awk '{print $2}' | xargs kill
sleep 2
source v2/.env && export NEBIUS_API_KEY NEBIUS_BASE_URL
cd v3 && mix ecto.migrate && mix phx.server
```

- [ ] **Step 2: Verify instance auto-restores from DB**

Check server logs for "Restored instance: igor"

- [ ] **Step 3: Send message to bot, verify it works**

- [ ] **Step 4: Verify dashboard shows instance with alive status**

Open http://localhost:4000, check instance appears

- [ ] **Step 5: Commit all remaining changes**

```bash
git add -A
git commit -m "supervision: complete Phase A implementation"
```
