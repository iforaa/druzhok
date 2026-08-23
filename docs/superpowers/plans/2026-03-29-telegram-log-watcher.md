# Telegram Log Watcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect unauthorized Telegram users from runtime container logs, send them a localized notification with their user ID, and create a pairing request on the dashboard for the owner to approve.

**Architecture:** A LogWatcher GenServer per instance tails `docker logs -f`, delegates line parsing to the runtime adapter's `parse_log_rejection/1` callback, creates deduplicated pairing requests, and sends Telegram messages via the existing `Druzhok.Telegram.Api` module.

**Tech Stack:** Elixir/OTP (GenServer, Port), Phoenix PubSub, SQLite (Ecto), Telegram Bot API

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `apps/druzhok/lib/druzhok/log_watcher.ex` | Create | GenServer: tail docker logs, parse, detect rejections |
| `apps/druzhok/lib/druzhok/runtime.ex` | Modify | Add `parse_log_rejection/1` callback |
| `apps/druzhok/lib/druzhok/runtime/pico_claw.ex` | Modify | Implement `parse_log_rejection/1` |
| `apps/druzhok/lib/druzhok/runtime/zero_claw.ex` | Modify | Implement `parse_log_rejection/1` |
| `apps/druzhok/lib/druzhok/bot_manager.ex` | Modify | Start/stop LogWatcher on instance start/stop |
| `apps/druzhok/lib/druzhok/i18n.ex` | Modify | Add rejection and welcome message strings |
| `apps/druzhok/lib/druzhok/instance.ex` | Modify | Add `reject_message` and `welcome_message` fields |
| `apps/druzhok/lib/druzhok/pairing.ex` | Modify | Add `create_request/4` for log-watcher-initiated requests |
| `apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex` | Modify | Wire approve to send welcome message, show pairing requests, settings fields |

---

### Task 1: Runtime Callback — `parse_log_rejection/1`

**Files:**
- Modify: `apps/druzhok/lib/druzhok/runtime.ex`
- Modify: `apps/druzhok/lib/druzhok/runtime/pico_claw.ex`
- Modify: `apps/druzhok/lib/druzhok/runtime/zero_claw.ex`

- [ ] **Step 1: Add callback to Runtime behaviour**

In `apps/druzhok/lib/druzhok/runtime.ex`, add after the `clear_sessions` callback:

```elixir
@callback parse_log_rejection(line :: String.t()) :: {:rejected, user_id :: String.t()} | :ignore
```

- [ ] **Step 2: Implement for PicoClaw**

In `apps/druzhok/lib/druzhok/runtime/pico_claw.ex`, add:

```elixir
@impl true
def parse_log_rejection(line) do
  case Regex.run(~r/rejected by allowlist.*user_id=(\S+)/, line) do
    [_, user_id] -> {:rejected, user_id}
    _ -> :ignore
  end
end
```

- [ ] **Step 3: Implement for ZeroClaw**

In `apps/druzhok/lib/druzhok/runtime/zero_claw.ex`, add:

```elixir
@impl true
def parse_log_rejection(line) do
  case Regex.run(~r/ignoring message from unauthorized user.*sender_id=(\S+)/, line) do
    [_, sender_id] when sender_id != "unknown" -> {:rejected, sender_id}
    _ -> :ignore
  end
end
```

- [ ] **Step 4: Compile and verify**

Run: `cd v4/druzhok && mix compile`
Expected: Clean compilation, no warnings about missing callbacks

- [ ] **Step 5: Commit**

```
git add apps/druzhok/lib/druzhok/runtime.ex apps/druzhok/lib/druzhok/runtime/pico_claw.ex apps/druzhok/lib/druzhok/runtime/zero_claw.ex
git commit -m "add parse_log_rejection callback to runtime adapters"
```

---

### Task 2: I18n Strings for Rejection and Welcome

**Files:**
- Modify: `apps/druzhok/lib/druzhok/i18n.ex`

- [ ] **Step 1: Add rejection and welcome strings**

In `apps/druzhok/lib/druzhok/i18n.ex`, add to the `@strings` map:

```elixir
:reject_default => %{
  "ru" => "Этот бот приватный. Ваш Telegram ID: %{user_id}. Запрос на доступ отправлен владельцу бота.",
  "en" => "This bot is private. Your Telegram ID: %{user_id}. Access request has been sent to the bot owner."
},
:welcome_default => %{
  "ru" => "Доступ одобрен! Можете начать общение с ботом.",
  "en" => "Access approved! You can now start chatting with the bot."
},
```

- [ ] **Step 2: Compile and verify**

Run: `cd v4/druzhok && mix compile`
Expected: Clean compilation

- [ ] **Step 3: Commit**

```
git add apps/druzhok/lib/druzhok/i18n.ex
git commit -m "add i18n strings for rejection and welcome messages"
```

---

### Task 3: Instance Schema — Add Message Fields

**Files:**
- Modify: `apps/druzhok/lib/druzhok/instance.ex`

- [ ] **Step 1: Add fields to schema**

In `apps/druzhok/lib/druzhok/instance.ex`, add inside the `schema "instances"` block:

```elixir
field :reject_message, :string
field :welcome_message, :string
```

- [ ] **Step 2: Add fields to changeset**

In the `changeset/2` function, add `:reject_message` and `:welcome_message` to the `cast` list.

- [ ] **Step 3: Create migration**

Run: `cd v4/druzhok && mix ecto.gen.migration add_instance_messages`

Edit the generated migration file:

```elixir
def change do
  alter table(:instances) do
    add :reject_message, :string
    add :welcome_message, :string
  end
end
```

- [ ] **Step 4: Run migration**

Run: `cd v4/druzhok && mix ecto.migrate`
Expected: Migration runs successfully

- [ ] **Step 5: Commit**

```
git add apps/druzhok/lib/druzhok/instance.ex apps/druzhok/priv/repo/migrations/*add_instance_messages*
git commit -m "add reject_message and welcome_message to instances"
```

---

### Task 4: Pairing Request for Log-Watcher

**Files:**
- Modify: `apps/druzhok/lib/druzhok/pairing.ex`

The existing `Pairing` module creates codes for manual pairing. The log watcher needs a simpler flow: just record that a user was rejected and wants access. Reuse the existing `pairings` table.

- [ ] **Step 1: Add `create_request/4` function**

In `apps/druzhok/lib/druzhok/pairing.ex`, add:

```elixir
@doc """
Creates a pairing request from the log watcher.
Returns {:ok, pairing} if new, {:exists, pairing} if already pending.
"""
def create_request(instance_name, telegram_user_id, username \\ nil, display_name \\ nil) do
  case get_pending(instance_name, telegram_user_id) do
    nil ->
      %Pairing{}
      |> changeset(%{
        instance_name: instance_name,
        code: "LOG-" <> generate_code(),
        telegram_user_id: telegram_user_id,
        username: username,
        display_name: display_name,
        expires_at: DateTime.add(DateTime.utc_now(), 30 * 86400, :second)
      })
      |> Repo.insert()
    existing ->
      {:exists, existing}
  end
end
```

- [ ] **Step 2: Add `get_pending/2` query (by instance + user_id)**

```elixir
def get_pending(instance_name, telegram_user_id) do
  from(p in Pairing,
    where: p.instance_name == ^instance_name
      and p.telegram_user_id == ^telegram_user_id
      and p.expires_at > ^DateTime.utc_now()
  )
  |> Repo.one()
end
```

- [ ] **Step 3: Add `pending_for_instance/1` to list all pending requests**

```elixir
def pending_for_instance(instance_name) do
  from(p in Pairing,
    where: p.instance_name == ^instance_name
      and p.expires_at > ^DateTime.utc_now(),
    order_by: [desc: :inserted_at]
  )
  |> Repo.all()
end
```

- [ ] **Step 4: Add `approve_request/2` to approve a specific user**

```elixir
def approve_request(instance_name, telegram_user_id) do
  case get_pending(instance_name, telegram_user_id) do
    nil -> {:error, :not_found}
    pairing ->
      Repo.delete(pairing)
      {:ok, pairing}
  end
end
```

- [ ] **Step 5: Compile and verify**

Run: `cd v4/druzhok && mix compile`
Expected: Clean compilation

- [ ] **Step 6: Commit**

```
git add apps/druzhok/lib/druzhok/pairing.ex
git commit -m "add log-watcher pairing request functions"
```

---

### Task 5: LogWatcher GenServer

**Files:**
- Create: `apps/druzhok/lib/druzhok/log_watcher.ex`

- [ ] **Step 1: Create the LogWatcher module**

Create `apps/druzhok/lib/druzhok/log_watcher.ex`:

```elixir
defmodule Druzhok.LogWatcher do
  @moduledoc """
  Tails docker logs for a bot instance, detects unauthorized Telegram users
  from runtime log output, and creates pairing requests.
  """
  use GenServer
  require Logger

  @format_check_interval :timer.hours(6)
  @format_warn_after :timer.hours(24)

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  def stop(instance_name) do
    case Registry.lookup(Druzhok.Registry, {instance_name, :log_watcher}) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  defp via(name), do: {:via, Registry, {Druzhok.Registry, {name, :log_watcher}}}

  @impl true
  def init(opts) do
    instance_name = Keyword.fetch!(opts, :name)
    runtime_module = Keyword.fetch!(opts, :runtime)
    bot_token = Keyword.fetch!(opts, :bot_token)
    language = Keyword.get(opts, :language, "ru")
    reject_message = Keyword.get(opts, :reject_message)

    container = Druzhok.BotManager.container_name(instance_name)

    port = Port.open(
      {:spawn_executable, "/usr/bin/env"},
      [
        :binary, :exit_status, :use_stdio, :stderr_to_stdout,
        args: ["docker", "logs", "-f", "--since=5s", container]
      ]
    )

    schedule_format_check()

    {:ok, %{
      instance_name: instance_name,
      runtime: runtime_module,
      bot_token: bot_token,
      language: language,
      reject_message: reject_message,
      port: port,
      buffer: "",
      last_rejection_at: nil,
      started_at: System.monotonic_time(:millisecond),
      format_warned: false
    }}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {lines, buffer} = split_lines(state.buffer <> data)

    state = Enum.reduce(lines, state, fn line, acc ->
      case acc.runtime.parse_log_rejection(line) do
        {:rejected, user_id} ->
          handle_rejection(acc, user_id)
          %{acc | last_rejection_at: System.monotonic_time(:millisecond)}
        :ignore ->
          acc
      end
    end)

    {:noreply, %{state | buffer: buffer}}
  end

  @impl true
  def handle_info({port, {:exit_status, _code}}, %{port: port} = state) do
    Logger.warning("LogWatcher port exited for #{state.instance_name}, stopping")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:check_format, state) do
    now = System.monotonic_time(:millisecond)
    uptime = now - state.started_at

    if uptime > @format_warn_after and state.last_rejection_at == nil and not state.format_warned do
      Druzhok.CrashLog.insert(%{
        level: "warning",
        message: "LogWatcher for #{state.instance_name}: no rejection patterns matched in 24h — runtime log format may have changed",
        source: "Druzhok.LogWatcher",
        instance_name: state.instance_name
      })
      schedule_format_check()
      {:noreply, %{state | format_warned: true}}
    else
      schedule_format_check()
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if Port.info(state.port), do: Port.close(state.port)
    :ok
  end

  defp handle_rejection(state, user_id) do
    case Druzhok.Pairing.create_request(state.instance_name, String.to_integer(user_id)) do
      {:ok, _pairing} ->
        send_rejection_message(state, user_id)
        Druzhok.Events.broadcast(state.instance_name, %{
          type: :pairing_request,
          user_id: user_id
        })
      {:exists, _} ->
        :ok
      {:error, reason} ->
        Logger.warning("LogWatcher: failed to create pairing request: #{inspect(reason)}")
    end
  end

  defp send_rejection_message(state, user_id) do
    text = if state.reject_message do
      String.replace(state.reject_message, "%{user_id}", user_id)
    else
      Druzhok.I18n.t(:reject_default, state.language, %{user_id: user_id})
    end

    case Druzhok.Telegram.Api.send_message(state.bot_token, user_id, text) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("LogWatcher: failed to send rejection message to #{user_id}: #{inspect(reason)}")
    end
  end

  defp split_lines(data) do
    parts = String.split(data, "\n")
    {Enum.slice(parts, 0..-2//1), List.last(parts)}
  end

  defp schedule_format_check do
    Process.send_after(self(), :check_format, @format_check_interval)
  end
end
```

- [ ] **Step 2: Compile and verify**

Run: `cd v4/druzhok && mix compile`
Expected: Clean compilation

- [ ] **Step 3: Commit**

```
git add apps/druzhok/lib/druzhok/log_watcher.ex
git commit -m "add LogWatcher GenServer for rejection detection"
```

---

### Task 6: Wire LogWatcher into BotManager

**Files:**
- Modify: `apps/druzhok/lib/druzhok/bot_manager.ex`

- [ ] **Step 1: Start LogWatcher in post_start Task**

In `apps/druzhok/lib/druzhok/bot_manager.ex`, find the `Task.start` block inside the `start/1` function that calls `runtime.post_start(instance)`. Replace it with:

```elixir
Task.start(fn ->
  case runtime.post_start(instance) do
    :ok -> :ok
    {:error, reason} ->
      Logger.error("Post-start config for #{name} failed: #{inspect(reason)}")
  end

  # Start log watcher for rejection detection
  Druzhok.LogWatcher.start_link(
    name: name,
    runtime: runtime,
    bot_token: instance.telegram_token,
    language: instance.language || "ru",
    reject_message: instance.reject_message
  )
end)
```

- [ ] **Step 2: Stop LogWatcher in stop/1**

In the `stop/1` function, add `Druzhok.LogWatcher.stop(name)` before `stop_container`:

```elixir
def stop(name) do
  Druzhok.LogWatcher.stop(name)
  stop_container(name)
  Druzhok.HealthMonitor.unregister(name)
  :ok
end
```

- [ ] **Step 3: Compile and verify**

Run: `cd v4/druzhok && mix compile`
Expected: Clean compilation

- [ ] **Step 4: Commit**

```
git add apps/druzhok/lib/druzhok/bot_manager.ex
git commit -m "wire LogWatcher start/stop into BotManager lifecycle"
```

---

### Task 7: Dashboard — Pairing Requests List and Approve with Welcome Message

**Files:**
- Modify: `apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex`

- [ ] **Step 1: Load pairing requests in socket assigns**

In the `load_instance_data` or equivalent function that runs when an instance is selected, add:

```elixir
pairing_requests: Druzhok.Pairing.pending_for_instance(name),
```

Also subscribe to events so new pairing requests trigger a UI update. In the `handle_info` for PubSub events, match on `:pairing_request` type and reload the list.

- [ ] **Step 2: Handle approve event**

Add a new event handler:

```elixir
def handle_event("approve_log_pairing", %{"user_id" => user_id_str}, socket) do
  name = socket.assigns.selected
  user_id = String.to_integer(user_id_str)

  instance = Druzhok.Repo.get_by(Druzhok.Instance, name: name)
  runtime = Druzhok.Runtime.get(instance.bot_runtime, Druzhok.Runtime.ZeroClaw)
  data_root = Path.dirname(instance.workspace)

  # Add to runtime allow_from
  runtime.add_allowed_user(data_root, user_id_str)

  # Delete pairing request
  Druzhok.Pairing.approve_request(name, user_id)

  # Send welcome message
  welcome = instance.welcome_message ||
    Druzhok.I18n.t(:welcome_default, instance.language || "ru")
  Druzhok.Telegram.Api.send_message(instance.telegram_token, user_id, welcome)

  # Broadcast and reload
  Druzhok.Events.broadcast(name, %{type: :pairing_approved, user_id: user_id_str})

  {:noreply, assign(socket,
    pairing_requests: Druzhok.Pairing.pending_for_instance(name),
    allowed_users: runtime.read_allowed_users(data_root)
  )}
end
```

- [ ] **Step 3: Add pairing requests section to Settings tab template**

In the Settings tab rendering section, add a pairing requests block before or after the allowed users section:

```heex
<%= if @pairing_requests != [] do %>
  <div class="bg-yellow-50 border border-yellow-200 rounded-lg p-4 mb-4">
    <h3 class="text-sm font-medium text-yellow-800 mb-2">Pending Access Requests</h3>
    <%= for req <- @pairing_requests do %>
      <div class="flex items-center justify-between py-2 border-b border-yellow-100 last:border-0">
        <div>
          <span class="font-mono text-sm"><%= req.telegram_user_id %></span>
          <%= if req.username do %>
            <span class="text-gray-500 text-sm ml-2">@<%= req.username %></span>
          <% end %>
        </div>
        <button phx-click="approve_log_pairing"
                phx-value-user_id={req.telegram_user_id}
                class="px-3 py-1 bg-green-600 text-white text-sm rounded hover:bg-green-700">
          Approve
        </button>
      </div>
    <% end %>
  </div>
<% end %>
```

- [ ] **Step 4: Add reject/welcome message fields to Settings tab**

In the Settings tab, add two textarea fields:

```heex
<div class="mt-4">
  <label class="block text-sm font-medium text-gray-700">Rejection Message (optional)</label>
  <textarea phx-blur="update_reject_message" phx-value-name={@selected}
            class="mt-1 block w-full rounded border-gray-300 text-sm"
            placeholder="Uses default if empty. Use %{user_id} for the user's ID."
            rows="2"><%= @instance.reject_message %></textarea>
</div>
<div class="mt-4">
  <label class="block text-sm font-medium text-gray-700">Welcome Message (optional)</label>
  <textarea phx-blur="update_welcome_message" phx-value-name={@selected}
            class="mt-1 block w-full rounded border-gray-300 text-sm"
            placeholder="Uses default if empty."
            rows="2"><%= @instance.welcome_message %></textarea>
</div>
```

- [ ] **Step 5: Handle message update events**

```elixir
def handle_event("update_reject_message", %{"name" => name, "value" => value}, socket) do
  value = if String.trim(value) == "", do: nil, else: String.trim(value)
  case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
    nil -> {:noreply, socket}
    inst ->
      Druzhok.Repo.update(Druzhok.Instance.changeset(inst, %{reject_message: value}))
      {:noreply, socket}
  end
end

def handle_event("update_welcome_message", %{"name" => name, "value" => value}, socket) do
  value = if String.trim(value) == "", do: nil, else: String.trim(value)
  case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
    nil -> {:noreply, socket}
    inst ->
      Druzhok.Repo.update(Druzhok.Instance.changeset(inst, %{welcome_message: value}))
      {:noreply, socket}
  end
end
```

- [ ] **Step 6: Reload pairing requests on PubSub event**

In the existing `handle_info` for PubSub events, add a match:

```elixir
%{type: :pairing_request} ->
  {:noreply, assign(socket,
    pairing_requests: Druzhok.Pairing.pending_for_instance(socket.assigns.selected)
  )}
```

- [ ] **Step 7: Compile and verify**

Run: `cd v4/druzhok && mix compile`
Expected: Clean compilation

- [ ] **Step 8: Commit**

```
git add apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex
git commit -m "dashboard: pairing requests list, approve with welcome, message settings"
```

---

### Task 8: Deploy and Test End-to-End

**Files:**
- No code changes — deployment and manual testing

- [ ] **Step 1: Sync code to server**

```bash
rsync -avz --delete --exclude='.git' --exclude='deps' --exclude='_build' --exclude='node_modules' --exclude='.elixir_ls' v4/druzhok/apps/ igor@158.160.78.230:~/druzhok/v4/druzhok/apps/
```

- [ ] **Step 2: Run migration on server**

```bash
ssh -l igor 158.160.78.230 "export PATH=/home/igor/.asdf/shims:/home/igor/.asdf/bin:\$PATH && cd ~/druzhok/v4/druzhok && DATABASE_PATH=/home/igor/druzhok-data/v4-druzhok.db mix ecto.migrate"
```

- [ ] **Step 3: Restart service**

```bash
ssh -l igor 158.160.78.230 "sudo systemctl stop druzhok; sudo pkill -9 -f beam.smp; sleep 3; sudo systemctl start druzhok"
```

- [ ] **Step 4: Test with vasa (PicoClaw)**

1. Open dashboard at https://oldey.dev
2. Start vasa instance
3. Send a Telegram message to vasa from an unauthorized account
4. Verify: rejection message received with Telegram ID
5. Verify: pairing request appears on dashboard Settings tab
6. Click Approve
7. Verify: welcome message received
8. Send another message — should get a response from the bot

- [ ] **Step 5: Test with igor (ZeroClaw)**

Same flow as Step 4 but with the igor instance.

- [ ] **Step 6: Test format-change detection**

Temporarily change the PicoClaw regex to something that won't match. Wait isn't practical (24h), so temporarily lower `@format_warn_after` to 60_000 (1 minute) and `@format_check_interval` to 10_000 (10 seconds). Send an unauthorized message. Verify the warning appears on the Errors tab. Revert the timing constants.

- [ ] **Step 7: Commit any fixes**

```
git add -A && git commit -m "fixes from end-to-end testing"
```
