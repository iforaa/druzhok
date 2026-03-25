# WebSocket Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a WebSocket channel so a React Native app can communicate with Druzhok bot instances alongside Telegram.

**Architecture:** A Phoenix Socket (`ChatSocket`) authenticates via instance API key. A Phoenix Channel (`ChatChannel`) handles message events, dispatches to `PiCore.Session`, and pushes streaming deltas + final responses back to the client.

**Tech Stack:** Elixir/OTP, Phoenix Channels, ExUnit

**Spec:** `docs/superpowers/specs/2026-03-25-websocket-channel-design.md`

---

## File Structure

### New files
- `v3/apps/druzhok_web/lib/druzhok_web_web/channels/chat_socket.ex` — WebSocket endpoint, API key auth
- `v3/apps/druzhok_web/lib/druzhok_web_web/channels/chat_channel.ex` — Message handling, Session dispatch
- `v3/apps/druzhok_web/test/druzhok_web_web/channels/chat_channel_test.exs`
- `v3/apps/druzhok/priv/repo/migrations/20260325000001_add_api_key_to_instances.exs`

### Modified files
- `v3/apps/druzhok_web/lib/druzhok_web_web/endpoint.ex` — add socket route
- `v3/apps/druzhok/lib/druzhok/instance.ex` — add api_key field
- `v3/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex` — API key generation UI

---

### Task 1: Migration + Instance schema

**Files:**
- Create: `v3/apps/druzhok/priv/repo/migrations/20260325000001_add_api_key_to_instances.exs`
- Modify: `v3/apps/druzhok/lib/druzhok/instance.ex`

- [ ] **Step 1: Create migration**

```elixir
defmodule Druzhok.Repo.Migrations.AddApiKeyToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :api_key, :string
    end

    create unique_index(:instances, [:api_key])
  end
end
```

- [ ] **Step 2: Run migration**

Run: `cd v3 && mix ecto.migrate`

- [ ] **Step 3: Update Instance schema**

In `v3/apps/druzhok/lib/druzhok/instance.ex`, add to schema:
```elixir
field :api_key, :string
```

Add `:api_key` to changeset cast list.

Add helper function:
```elixir
def get_by_api_key(nil), do: nil
def get_by_api_key(key), do: Druzhok.Repo.get_by(__MODULE__, api_key: key)

def generate_api_key do
  "dk_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
```

- [ ] **Step 4: Compile and verify**

Run: `cd v3 && mix compile`

- [ ] **Step 5: Commit**

Message: `add api_key field to instances`

---

### Task 2: ChatSocket + ChatChannel

**Files:**
- Create: `v3/apps/druzhok_web/lib/druzhok_web_web/channels/chat_socket.ex`
- Create: `v3/apps/druzhok_web/lib/druzhok_web_web/channels/chat_channel.ex`
- Modify: `v3/apps/druzhok_web/lib/druzhok_web_web/endpoint.ex`

- [ ] **Step 1: Create ChatSocket**

```elixir
# v3/apps/druzhok_web/lib/druzhok_web_web/channels/chat_socket.ex
defmodule DruzhokWebWeb.ChatSocket do
  use Phoenix.Socket

  channel "chat:*", DruzhokWebWeb.ChatChannel

  @impl true
  def connect(%{"api_key" => api_key}, socket, _connect_info) do
    case Druzhok.Instance.get_by_api_key(api_key) do
      %{name: name, active: true} ->
        {:ok, assign(socket, :instance_name, name)}
      _ ->
        :error
    end
  end

  def connect(_, _, _), do: :error

  @impl true
  def id(socket), do: "chat_socket:#{socket.assigns.instance_name}"
end
```

- [ ] **Step 2: Create ChatChannel**

```elixir
# v3/apps/druzhok_web/lib/druzhok_web_web/channels/chat_channel.ex
defmodule DruzhokWebWeb.ChatChannel do
  use DruzhokWebWeb, :channel

  alias Druzhok.Instance.SessionSup

  @impl true
  def join("chat:lobby", _payload, socket) do
    {:ok, socket}
  end

  def join(_, _, _), do: {:error, %{reason: "invalid topic"}}

  @impl true
  def handle_in("message", %{"text" => text, "chat_id" => chat_id}, socket) do
    instance_name = socket.assigns.instance_name
    dispatch_prompt(instance_name, chat_id, text)
    {:noreply, socket}
  end

  def handle_in("reset", %{"chat_id" => chat_id}, socket) do
    instance_name = socket.assigns.instance_name
    case Registry.lookup(Druzhok.Registry, {instance_name, :session, chat_id}) do
      [{pid, _}] -> PiCore.Session.reset(pid)
      [] -> :ok
    end
    {:noreply, socket}
  end

  def handle_in("abort", %{"chat_id" => chat_id}, socket) do
    instance_name = socket.assigns.instance_name
    case Registry.lookup(Druzhok.Registry, {instance_name, :session, chat_id}) do
      [{pid, _}] -> PiCore.Session.abort(pid)
      [] -> :ok
    end
    {:noreply, socket}
  end

  # Session sends streaming deltas
  @impl true
  def handle_info({:pi_delta, chunk, chat_id}, socket) do
    push(socket, "delta", %{text: chunk, chat_id: chat_id})
    {:noreply, socket}
  end

  def handle_info({:pi_delta, chunk}, socket) do
    push(socket, "delta", %{text: chunk})
    {:noreply, socket}
  end

  # Session sends final response
  def handle_info({:pi_response, %{text: text} = payload}, socket) when is_binary(text) and text != "" do
    push(socket, "response", payload)
    {:noreply, socket}
  end

  def handle_info({:pi_response, %{error: true, text: text}}, socket) do
    push(socket, "error", %{text: text})
    {:noreply, socket}
  end

  def handle_info({:pi_response, _}, socket), do: {:noreply, socket}

  # Catch-all
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp dispatch_prompt(instance_name, chat_id, text) do
    case Registry.lookup(Druzhok.Registry, {instance_name, :session, chat_id}) do
      [{pid, _}] ->
        PiCore.Session.prompt(pid, text)
      [] ->
        case SessionSup.start_session(instance_name, chat_id, %{group: false}) do
          {:ok, pid} -> PiCore.Session.prompt(pid, text)
          {:error, reason} ->
            require Logger
            Logger.error("WebSocket: failed to start session for #{chat_id}: #{inspect(reason)}")
        end
    end
  end
end
```

**IMPORTANT**: The Channel process needs to receive `{:pi_delta, ...}` and `{:pi_response, ...}` messages from the Session. Currently, `Instance.Sup` configures `on_delta` as a function that sends to the Telegram GenServer via Registry lookup. For WebSocket, the Session needs to know to send to the Channel process instead.

The simplest fix: when `dispatch_prompt` starts or finds a session, it also tells the session to send responses to `self()` (the Channel process). Check how `Agent.Telegram` does this — it uses `{:set_caller, pid}` cast. The Channel should do the same after dispatch:

```elixir
defp dispatch_prompt(instance_name, chat_id, text) do
  pid = case Registry.lookup(Druzhok.Registry, {instance_name, :session, chat_id}) do
    [{pid, _}] -> pid
    [] ->
      case SessionSup.start_session(instance_name, chat_id, %{group: false}) do
        {:ok, pid} -> pid
        {:error, _} -> nil
      end
  end

  if pid do
    GenServer.cast(pid, {:set_caller, self()})
    PiCore.Session.prompt(pid, text)
  end
end
```

Wait — check if `on_delta` in Session.Sup is a function closure that sends to Telegram. If so, the delta path goes through `on_delta` (to Telegram), not `caller`. Read Session to understand the response routing:

Looking at Session: `deliver_last_assistant/3` sends `{:pi_response, ...}` to `state.caller` or to the Telegram process via Registry lookup. The `on_delta` sends `{:pi_delta, ...}` via the closure set in Instance.Sup.

For WebSocket, we need to override BOTH:
1. `caller` → set to the Channel process (for `{:pi_response, ...}`)
2. `on_delta` → needs to also send to the Channel process

The simplest approach: use `{:set_caller, self()}` which handles `{:pi_response, ...}`. For deltas, the `on_delta` closure in Instance.Sup sends to the Telegram process. But the Channel process also needs them.

**Revised approach**: The Session's `on_delta` closure sends to whoever is in `state.caller`. Let me check the actual code...

Actually, looking at `Instance.Sup`, `on_delta` sends to the process registered as `{name, :telegram}`. For WebSocket, we don't have that. The cleanest fix: Session should send deltas to `state.caller` (same as responses) instead of through the `on_delta` closure. But that would change Telegram behavior too.

**Simplest non-breaking approach**: After starting the session, the Channel tells it to use the Channel's pid as caller. The Session wraps `on_delta` to send to `state.chat_id`-specific caller. Since `deliver_last_assistant` already uses `state.caller` when `instance_name` lookup fails, setting `caller` to the Channel process should work for `{:pi_response, ...}`.

For `{:pi_delta, ...}`: the `on_delta` closure in Session.run_prompt sends to Telegram via the Registry. The Channel won't receive deltas through this path.

**Fix**: Add a `handle_cast({:set_caller, pid})` that ALSO updates `on_delta` to send to the new caller:

No — that's too invasive. Let the Channel subscribe to the Events system instead for deltas. Or accept that WebSocket gets response-only for now, and add delta forwarding later.

**Actually the simplest**: The `on_delta` in `run_prompt/2` wraps `state.on_delta` with `state.chat_id`. If `state.caller` is the Channel process and `state.on_delta` is set to a function that sends to `state.caller`, it works. But `on_delta` is set at instance startup, not per-session.

**Final approach**: In `dispatch_prompt`, after setting caller, also subscribe the Channel to Events for this instance. The Events system broadcasts all events including deltas. The Channel filters for its chat_id.

Actually, let me re-read the Session code one more time. The `on_delta` in `run_prompt`:

```elixir
wrapped_on_delta = if state.on_delta && state.chat_id do
  fn chunk -> state.on_delta.(chunk, state.chat_id) end
else
  state.on_delta
end
```

And `on_delta` in Instance.Sup:
```elixir
on_delta = fn chunk, chat_id ->
  case Registry.lookup(Druzhok.Registry, {name, :telegram}) do
    [{pid, _}] -> send(pid, {:pi_delta, chunk, chat_id})
    [] -> :ok
  end
end
```

So deltas go to Telegram only. For the Channel, we need the Session to ALSO send deltas to the caller. The simplest code change: in `run_prompt`, after the existing `on_delta` wrapper, add a caller notification:

No — let's keep it simple. **For the MVP, the WebSocket channel gets `response` events only (no streaming deltas).** The app can show a loading indicator. We'll add delta streaming in a follow-up.

This keeps Task 2 clean.

- [ ] **Step 3: Add socket route to endpoint**

In `v3/apps/druzhok_web/lib/druzhok_web_web/endpoint.ex`, add after the LiveView socket:

```elixir
socket "/socket/chat", DruzhokWebWeb.ChatSocket,
  websocket: true
```

- [ ] **Step 4: Compile and verify**

Run: `cd v3 && mix compile`

- [ ] **Step 5: Commit**

Message: `add ChatSocket and ChatChannel for WebSocket communication`

---

### Task 3: Dashboard — API key management

**Files:**
- Modify: `v3/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex`

- [ ] **Step 1: Add API key UI**

Read dashboard_live.ex. Find where instance details are shown (the selected instance panel). Add an API Key section.

In the instance detail area, add:
```heex
<div class="bg-white rounded-xl border border-gray-200 p-4 mt-4">
  <h3 class="text-sm font-semibold mb-2">API Key (for app connections)</h3>
  <div :if={@selected_instance && @selected_instance.api_key}>
    <div class="flex items-center gap-2">
      <code class="text-xs font-mono bg-gray-100 px-2 py-1 rounded flex-1 truncate"><%= mask_api_key(@selected_instance.api_key) %></code>
      <button phx-click="regenerate_api_key" phx-value-name={@selected}
              data-confirm="Regenerate API key? Existing connections will break."
              class="text-xs text-red-600 hover:underline">Regenerate</button>
    </div>
  </div>
  <div :if={!@selected_instance || !@selected_instance.api_key}>
    <button phx-click="generate_api_key" phx-value-name={@selected}
            class="bg-gray-900 hover:bg-gray-800 text-white rounded-lg px-3 py-1.5 text-xs font-medium transition">
      Generate API Key
    </button>
  </div>
</div>
```

Add assigns: `selected_instance: nil` in mount, and load it when selecting an instance.

Add event handlers:
```elixir
def handle_event("generate_api_key", %{"name" => name}, socket) do
  instance = Druzhok.Repo.get_by(Druzhok.Instance, name: name)
  if instance do
    key = Druzhok.Instance.generate_api_key()
    instance |> Druzhok.Instance.changeset(%{api_key: key}) |> Druzhok.Repo.update()
  end
  {:noreply, assign(socket, selected_instance: Druzhok.Repo.get_by(Druzhok.Instance, name: name))}
end

def handle_event("regenerate_api_key", params, socket) do
  handle_event("generate_api_key", params, socket)
end
```

Add helper:
```elixir
defp mask_api_key(nil), do: ""
defp mask_api_key(key) when byte_size(key) > 10 do
  String.slice(key, 0, 7) <> "..." <> String.slice(key, -4, 4)
end
defp mask_api_key(key), do: key
```

- [ ] **Step 2: Compile and verify**

Run: `cd v3 && mix compile`

- [ ] **Step 3: Commit**

Message: `add API key generation to dashboard`

---

### Task 4: Add delta streaming to WebSocket

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/session.ex`
- Modify: `v3/apps/druzhok_web/lib/druzhok_web_web/channels/chat_channel.ex`

Now add streaming delta support. The Session needs to also send deltas to `state.caller`.

- [ ] **Step 1: Update Session.run_prompt to send deltas to caller**

In `v3/apps/pi_core/lib/pi_core/session.ex`, in `run_prompt/2`, update the `wrapped_on_delta`:

```elixir
wrapped_on_delta = if state.on_delta && state.chat_id do
  fn chunk -> state.on_delta.(chunk, state.chat_id) end
else
  state.on_delta
end

# Also send deltas to caller (for WebSocket channel support)
caller_delta = if state.caller && state.chat_id do
  fn chunk ->
    if wrapped_on_delta, do: wrapped_on_delta.(chunk)
    send(state.caller, {:pi_delta, chunk, state.chat_id})
  end
else
  wrapped_on_delta
end
```

Then pass `caller_delta` instead of `wrapped_on_delta` to `Loop.run`.

Wait — this would cause Telegram to receive deltas twice (once via on_delta to Telegram GenServer, and once via caller which is ALSO the Telegram GenServer). We need to avoid double-sending.

**Better approach**: Only send to caller if caller is NOT the Telegram process. Check by comparing `state.caller` with the Telegram registry entry:

That's too complex. **Simplest**: Make `on_delta` ALWAYS send to caller. Remove the Telegram-specific `on_delta` closure from Instance.Sup. Instead, Session always sends `{:pi_delta, chunk, chat_id}` to `state.caller`.

In Instance.Sup, change `on_delta` to nil (or remove it):
```elixir
on_delta: nil,  # deltas sent to caller directly by Session
```

In Session.run_prompt, replace the on_delta wrapping with:
```elixir
wrapped_on_delta = if state.chat_id do
  caller = state.caller
  chat_id = state.chat_id
  fn chunk ->
    if caller, do: send(caller, {:pi_delta, chunk, chat_id})
  end
else
  nil
end
```

This way, both Telegram and WebSocket receive deltas the same way — via `{:pi_delta, chunk, chat_id}` to their process. Telegram already handles this message. WebSocket Channel already handles it.

But wait — what about the Telegram process? Currently `on_delta` in Instance.Sup sends to Telegram via Registry lookup `{name, :telegram}`. If we change to sending to `state.caller`, and `state.caller` is set to... what?

For Telegram: `state.caller` defaults to `opts[:caller] || self()` in init. But Session is started by SessionSup, not by Telegram. So `state.caller` is the SessionSup process, not Telegram.

Telegram calls `dispatch_prompt` which sends to the Session, but doesn't set itself as caller. The Session init uses `self()` (the Session process) as default caller.

Actually, looking more carefully at Session: `deliver_last_assistant` checks for `state.instance_name` and does a Registry lookup for `{instance_name, :telegram}` to find the Telegram process. So Telegram gets responses via Registry, not via caller.

For deltas: `on_delta` in Instance.Sup also does a Registry lookup for `{name, :telegram}`.

**So the pattern is: both deltas and responses go to Telegram via Registry lookup, not via caller.**

For WebSocket, we don't have a Registry entry. The Channel process is transient.

**The clean approach**: In `dispatch_prompt` in the ChatChannel, after sending the prompt, call `GenServer.cast(pid, {:set_caller, self()})`. The Session will then send `{:pi_response, ...}` to the Channel process (this already works — `deliver_last_assistant` falls back to `state.caller` when there's no Telegram in Registry).

For deltas: we need to ALSO set on_delta. Add a new Session cast: `{:set_on_delta, fn}`.

**Actually, simplest of all**: Just add a `:set_caller` cast in Session that updates BOTH caller and on_delta:

No, let's keep it really simple for MVP:

- [ ] **Step 1: Add :set_delta_target cast to Session**

In Session, add:
```elixir
def handle_cast({:set_caller, pid}, state) do
  on_delta = if state.chat_id do
    chat_id = state.chat_id
    fn chunk -> send(pid, {:pi_delta, chunk, chat_id}) end
  else
    fn chunk -> send(pid, {:pi_delta, chunk}) end
  end
  {:noreply, %{state | caller: pid, on_delta: on_delta}}
end
```

This replaces the existing `set_caller` handler. Now when WebSocket Channel calls `set_caller`, both responses AND deltas go to the Channel process.

For Telegram: Telegram never calls `set_caller` — it uses Registry lookup. So Telegram behavior is unchanged.

- [ ] **Step 2: Update ChatChannel dispatch_prompt**

Already shown above — after getting the session pid, call:
```elixir
GenServer.cast(pid, {:set_caller, self()})
```

- [ ] **Step 3: Run tests**

Run: `cd v3 && mix test --exclude slow`

- [ ] **Step 4: Commit**

Message: `add delta streaming support for WebSocket channel`

---

### Task 5: Channel tests

**Files:**
- Create: `v3/apps/druzhok_web/test/druzhok_web_web/channels/chat_channel_test.exs`

- [ ] **Step 1: Write tests**

```elixir
defmodule DruzhokWebWeb.ChatChannelTest do
  use ExUnit.Case

  # Basic smoke tests - full integration requires running instance

  test "ChatSocket rejects connection without api_key" do
    assert :error = DruzhokWebWeb.ChatSocket.connect(%{}, %Phoenix.Socket{}, %{})
  end

  test "ChatSocket rejects invalid api_key" do
    assert :error = DruzhokWebWeb.ChatSocket.connect(%{"api_key" => "invalid"}, %Phoenix.Socket{}, %{})
  end

  test "Instance.generate_api_key generates dk_ prefixed key" do
    key = Druzhok.Instance.generate_api_key()
    assert String.starts_with?(key, "dk_")
    assert byte_size(key) == 35  # "dk_" + 32 hex chars
  end
end
```

- [ ] **Step 2: Run tests**

Run: `cd v3 && mix test apps/druzhok_web/test/druzhok_web_web/channels/`

- [ ] **Step 3: Commit**

Message: `add ChatChannel tests`

---

### Task 6: Full test run and cleanup

- [ ] **Step 1: Run full test suite**

Run: `cd v3 && mix test --exclude slow`

- [ ] **Step 2: Check for warnings**

Run: `cd v3 && mix compile --warnings-as-errors 2>&1 | grep "warning:" | grep -v "apps/data\|Reminder\|catch.*rescue\|unused.*data\|never match\|Bcrypt\|telegram_pid\|clauses.*handle_info"`

- [ ] **Step 3: Commit if needed**

Message: `fix warnings from WebSocket channel`
