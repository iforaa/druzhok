# Phase A: Instance Supervision — Design Spec

## Goal

Replace ad-hoc process management with proper OTP supervision so instances auto-recover from crashes without losing state or requiring manual intervention.

## Current State

- `InstanceManager` starts Telegram, Session, Scheduler as unlinked processes
- PIDs tracked in an in-memory Agent (`InstanceRegistry`)
- If any process crashes, the instance is permanently broken until server restart
- Telegram and Session hold each other's PIDs directly — a restart makes the other's reference stale

## Architecture

### Supervision Tree

```
Druzhok.Supervisor (Application, one_for_one)
├── Druzhok.Repo
├── Registry (Druzhok.Registry)
├── Druzhok.InstanceDynSup (DynamicSupervisor)
│   ├── Druzhok.Instance.Sup "igor" (Supervisor, one_for_one, max_restarts: 3, max_seconds: 60)
│   │   ├── Druzhok.Agent.Telegram  — registered as {:via, Registry, {Druzhok.Registry, {"igor", :telegram}}}
│   │   ├── PiCore.Session           — registered as {:via, Registry, {Druzhok.Registry, {"igor", :session}}}
│   │   └── Druzhok.Scheduler        — registered as {:via, Registry, {Druzhok.Registry, {"igor", :scheduler}}}
│   ├── Druzhok.Instance.Sup "alice"
│   │   └── ...
├── Druzhok.InstanceWatcher (GenServer — monitors instance Sup PIDs for crash detection)
```

### Key Decisions

**Independent restarts (one_for_one):** Telegram crash doesn't restart Session and vice versa. Conversation history (in Session memory) survives a Telegram crash. Workspace files survive any crash.

**Max 3 restarts per 60 seconds:** If an instance crashes repeatedly (bad token, API down), the per-instance Supervisor terminates. This prevents crash loops from burning resources. A `{:instance_crashed}` event is broadcast to the dashboard.

**Registry-based PID resolution:** Processes find each other via `Druzhok.Registry` instead of storing PIDs. This means a restarted process gets a new PID and the registry entry updates automatically. Callers that look up a PID and find `nil` (process restarting) drop the message gracefully.

## Components

### 1. Druzhok.InstanceDynSup

Replaces the `InstanceRegistry` Agent. A `DynamicSupervisor` that holds per-instance supervisors.

```elixir
# Start instance:
DynamicSupervisor.start_child(Druzhok.InstanceDynSup, {Druzhok.Instance.Sup, opts})

# Stop instance:
DynamicSupervisor.terminate_child(Druzhok.InstanceDynSup, pid)
```

### 2. Druzhok.Instance.Sup

Per-instance Supervisor. Strategy: `:one_for_one`, `max_restarts: 3`, `max_seconds: 60`.

Init receives instance config map: `%{name, token, model, workspace, api_url, api_key, heartbeat_interval}`.

**Startup ordering and wiring:**

Children start in order: Telegram (with `session_pid: nil`), Session, Scheduler. After all children start, Telegram still needs the Session PID. This is handled the same way as today — via the `{:set_session, pid}` cast — but using Registry:

```elixir
def init(config) do
  children = [
    {Druzhok.Agent.Telegram, %{token: config.token, instance_name: config.name, ...}},
    {PiCore.Session, %{instance_name: config.name, ...}},
    {Druzhok.Scheduler, %{instance_name: config.name, ...}},
  ]

  # After supervision starts, Telegram already registered.
  # It begins polling only after receiving :set_session cast.
  # Session registers, then we wire them:
  Task.start(fn ->
    Process.sleep(100)
    case Registry.lookup(Druzhok.Registry, {config.name, :session}) do
      [{session_pid, _}] ->
        case Registry.lookup(Druzhok.Registry, {config.name, :telegram}) do
          [{telegram_pid, _}] -> GenServer.cast(telegram_pid, {:set_session, session_pid})
          _ -> :ok
        end
      _ -> :ok
    end
  end)

  Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 60)
end
```

Note: The wiring Task is fire-and-forget. If Telegram restarts later, it re-registers and starts with `session_pid: nil`. It resolves the Session PID via Registry lookup when it actually needs to dispatch a message (not at init time).

Each child registers itself in `Druzhok.Registry` with key `{instance_name, :role}` in its own `init/1`, using `{:via, Registry, {Druzhok.Registry, {name, :role}}}` as the GenServer name.

### 3. Druzhok.InstanceWatcher

A GenServer started as a child of the Application supervisor. Its job: monitor per-instance Supervisor PIDs and handle crashes.

```elixir
defmodule Druzhok.InstanceWatcher do
  use GenServer

  def watch(instance_name, sup_pid) do
    GenServer.cast(__MODULE__, {:watch, instance_name, sup_pid})
  end

  def handle_cast({:watch, name, pid}, state) do
    Process.monitor(pid)
    {:noreply, Map.put(state, pid, name)}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Map.pop(state, pid) do
      {nil, state} -> {:noreply, state}
      {name, state} ->
        Druzhok.Events.broadcast(name, %{type: :instance_crashed, reason: inspect(reason)})
        # Mark DB inactive so it doesn't auto-restore into a crash loop
        case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
          nil -> :ok
          inst -> Druzhok.Repo.update(Druzhok.Instance.changeset(inst, %{active: false}))
        end
        {:noreply, state}
    end
  end
end
```

When `InstanceManager.create/2` starts an instance Sup, it calls `InstanceWatcher.watch(name, sup_pid)`.

When the per-instance Sup dies (max_restarts exceeded), the watcher receives `{:DOWN, ...}`, broadcasts `{:instance_crashed}` event, and sets `active: false` in DB. On next app restart, the crashed instance is NOT auto-restored — the user must manually restart it via the dashboard.

### 4. PID Resolution via Registry

**Shared lookup helper** (in `Druzhok.Instance.Lookup` or inline):
```elixir
defp lookup(instance_name, role) do
  case Registry.lookup(Druzhok.Registry, {instance_name, role}) do
    [{pid, _}] -> pid
    [] -> nil
  end
end
```

**How each callback changes:**

`on_delta` — Built inside `Druzhok.Instance.Sup.init/1` as a closure over `instance_name` (not a PID). Does Registry lookup at call time:
```elixir
on_delta = fn chunk ->
  case Registry.lookup(Druzhok.Registry, {config.name, :telegram}) do
    [{pid, _}] -> send(pid, {:pi_delta, chunk})
    [] -> :ok  # Telegram restarting, drop chunk
  end
end
```

`caller` in Session — Session no longer stores a `caller` PID. Instead, `deliver_last_assistant/3` uses Registry lookup:
```elixir
defp deliver_last_assistant(new_messages, ref, state) do
  case Enum.find(Enum.reverse(new_messages), &(&1.role == "assistant")) do
    nil -> :ok
    msg ->
      case Registry.lookup(Druzhok.Registry, {state.instance_name, :telegram}) do
        [{pid, _}] -> send(pid, {:pi_response, %{text: msg.content, prompt_id: ref}})
        [] -> :ok
      end
  end
end
```

`send_file_fn` — Same pattern, closure over `instance_name`:
```elixir
send_file_fn = fn file_path, caption ->
  case Registry.lookup(Druzhok.Registry, {config.name, :telegram}) do
    [{pid, _}] ->
      chat_id = GenServer.call(pid, :get_chat_id, 5_000)
      if chat_id, do: API.send_document(config.token, chat_id, file_path, %{caption: caption}), else: {:error, "No active chat"}
    [] -> {:error, "Telegram not available"}
  end
end
```

Telegram dispatching to Session — Telegram stores `instance_name`, looks up `:session` via Registry:
```elixir
defp dispatch_prompt(text, state) do
  case Registry.lookup(Druzhok.Registry, {state.instance_name, :session}) do
    [{pid, _}] -> PiCore.Session.prompt(pid, text)
    [] -> :ok  # Session restarting, drop message
  end
end
```

Scheduler — Same pattern for heartbeat/reminder prompts.

### 5. InstanceManager Changes

Becomes a thin wrapper. No more Agent.

```elixir
def create(name, opts) do
  config = %{
    name: name,
    token: opts.telegram_token,
    model: opts.model,
    workspace: opts.workspace,
    api_url: opts.api_url,
    api_key: opts.api_key,
    heartbeat_interval: opts[:heartbeat_interval] || 0,
  }

  ensure_workspace(config.workspace)

  case DynamicSupervisor.start_child(Druzhok.InstanceDynSup, {Druzhok.Instance.Sup, config}) do
    {:ok, sup_pid} ->
      Druzhok.InstanceWatcher.watch(name, sup_pid)
      save_to_db(name, opts)
      {:ok, %{name: name, model: config.model}}

    {:error, {:already_started, _pid}} ->
      # Idempotent — instance already running (e.g., duplicate restore)
      {:ok, %{name: name, model: config.model}}

    {:error, reason} ->
      {:error, reason}
  end
end
```

`list/0` — DB is the authoritative source for metadata. Registry confirms which are alive:
```elixir
def list do
  import Ecto.Query
  instances = Druzhok.Repo.all(from i in Druzhok.Instance, where: i.active == true)

  Enum.map(instances, fn inst ->
    alive = Registry.lookup(Druzhok.Registry, {inst.name, :telegram}) != []
    %{name: inst.name, model: inst.model, heartbeat_interval: inst.heartbeat_interval, alive: alive}
  end)
end
```

`update_model/2` — Registry lookup + synchronous DB write:
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
```

### 6. Application.ex Changes

```elixir
children = [
  Druzhok.Repo,
  {Registry, keys: :unique, name: Druzhok.Registry},
  {DynamicSupervisor, name: Druzhok.InstanceDynSup, strategy: :one_for_one},
  Druzhok.InstanceWatcher,
  {Task, &restore_instances/0},  # temporary: true — won't restart on crash
]

opts = [strategy: :one_for_one, name: Druzhok.Supervisor]
```

The restore Task uses `Supervisor.child_spec({Task, ...}, restart: :temporary)` so it runs once and doesn't restart on failure.

`restore_instances/0` calls `InstanceManager.create/2` which handles `{:error, {:already_started, _}}` gracefully — safe for double-restore.

### 7. PiCore.Session Registration

Session needs to register in the Registry. Since Session is in the `pi_core` app (shared library), it should not depend on `Druzhok.Registry` directly. Instead, the registration name is passed via opts:

```elixir
# In Instance.Sup, when building the Session child spec:
{PiCore.Session, %{
  name: {:via, Registry, {Druzhok.Registry, {config.name, :session}}},
  instance_name: config.name,
  ...
}}

# In Session.start_link:
def start_link(opts) do
  name = opts[:name]  # nil for tests, {:via, ...} for production
  GenServer.start_link(__MODULE__, opts, name: name && [name: name] || [])
end
```

This keeps pi_core decoupled — it doesn't know about Druzhok.Registry; it just accepts an optional `:name`.

## Tests

All tests use `Process.exit(pid, :kill)` for crashes (abnormal exit that counts toward `max_restarts`).

1. **Instance starts all 3 children** — create instance, verify 3 processes registered in Registry
2. **Telegram crash doesn't affect Session** — kill Telegram via `Process.exit(pid, :kill)`, verify Session still alive and responds to prompts, verify Telegram restarts (new PID in Registry)
3. **Session crash doesn't affect Telegram** — kill Session, verify Telegram still registered and can poll
4. **Scheduler crash independent** — kill Scheduler, verify other two unaffected
5. **Max restarts stops instance** — kill a child with `Process.exit(pid, :kill)` 4 times within 60 seconds (use `Process.sleep(10)` between kills to let Supervisor restart), verify the per-instance Supervisor is dead and Watcher receives the DOWN
6. **Registry lookup returns nil during restart** — verify calling `on_delta` or `dispatch_prompt` when target is nil doesn't crash the caller
7. **Instance restore from DB** — insert active instance in DB, start app, verify it comes up under DynamicSupervisor
8. **Stop instance terminates subtree** — stop via InstanceManager, verify all 3 processes dead and Registry entries gone
9. **Create is idempotent** — call `create` twice with same name, second returns `{:ok, ...}` without error
10. **Crashed instance not auto-restored** — after max_restarts kills an instance, verify DB has `active: false`, restart app, verify instance is NOT restored

## Files Changed

- **New:** `apps/druzhok/lib/druzhok/instance/sup.ex` — per-instance Supervisor
- **New:** `apps/druzhok/lib/druzhok/instance_watcher.ex` — monitors instance Sups for crash detection
- **Modified:** `apps/druzhok/lib/druzhok/application.ex` — replace Agent with DynamicSupervisor + Watcher
- **Modified:** `apps/druzhok/lib/druzhok/instance_manager.ex` — use DynSup + Registry, remove Agent
- **Modified:** `apps/druzhok/lib/druzhok/agent/telegram.ex` — register in Registry, lookup Session via Registry, remove stored `session_pid` (keep only for initial wiring)
- **Modified:** `apps/pi_core/lib/pi_core/session.ex` — accept optional `:name` for Registry registration, use Registry lookup for `deliver_last_assistant` instead of stored `caller` PID
- **Modified:** `apps/druzhok/lib/druzhok/scheduler.ex` — register in Registry, lookup Session via Registry
- **Deleted:** all `Druzhok.InstanceRegistry` Agent usage
- **New:** `apps/druzhok/test/druzhok/supervision_test.exs`
- **Modified:** `apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex` — `list_instances` calls `InstanceManager.list/0` instead of Agent
