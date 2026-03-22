# Group Chat Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable bot instances to participate in Telegram group chats with DM pairing security, group approval, trigger-based responses, and per-chat session isolation.

**Architecture:** Telegram bot becomes a routing layer that checks DM ownership (via one-time pairing code) and group approval (via dashboard) before dispatching messages. Each chat_id gets its own Session under a per-instance DynamicSupervisor. Sessions share the workspace but have independent conversation history.

**Tech Stack:** Elixir OTP, Ecto/SQLite, Phoenix LiveView, Telegram Bot API

**Spec:** `docs/superpowers/specs/2026-03-22-group-chats-design.md`

---

### Task 1: DB Schemas — AllowedChat, PairingCode, Instance owner

**Files:**
- Create: `v3/apps/druzhok/priv/repo/migrations/20260322000007_create_allowed_chats_and_pairing.exs`
- Create: `v3/apps/druzhok/lib/druzhok/allowed_chat.ex`
- Create: `v3/apps/druzhok/lib/druzhok/pairing.ex`
- Modify: `v3/apps/druzhok/lib/druzhok/instance.ex`

- [ ] **Step 1: Create migration**

```elixir
defmodule Druzhok.Repo.Migrations.CreateAllowedChatsAndPairing do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :owner_telegram_id, :bigint
    end

    create table(:allowed_chats) do
      add :instance_name, :string, null: false
      add :chat_id, :bigint, null: false
      add :chat_type, :string, null: false
      add :title, :string
      add :telegram_user_id, :bigint
      add :status, :string, null: false, default: "pending"
      add :info_sent, :boolean, default: false
      timestamps()
    end

    create unique_index(:allowed_chats, [:instance_name, :chat_id])

    create table(:pairing_codes) do
      add :instance_name, :string, null: false
      add :code, :string, null: false
      add :telegram_user_id, :bigint, null: false
      add :username, :string
      add :display_name, :string
      add :expires_at, :utc_datetime, null: false
      timestamps()
    end

    create unique_index(:pairing_codes, [:instance_name])
  end
end
```

- [ ] **Step 2: Create AllowedChat schema**

```elixir
# v3/apps/druzhok/lib/druzhok/allowed_chat.ex
defmodule Druzhok.AllowedChat do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  schema "allowed_chats" do
    field :instance_name, :string
    field :chat_id, :integer
    field :chat_type, :string
    field :title, :string
    field :telegram_user_id, :integer
    field :status, :string, default: "pending"
    field :info_sent, :boolean, default: false
    timestamps()
  end

  def changeset(chat, attrs) do
    chat
    |> cast(attrs, [:instance_name, :chat_id, :chat_type, :title, :telegram_user_id, :status, :info_sent])
    |> validate_required([:instance_name, :chat_id, :chat_type])
    |> unique_constraint([:instance_name, :chat_id])
  end

  def get(instance_name, chat_id) do
    Druzhok.Repo.get_by(__MODULE__, instance_name: instance_name, chat_id: chat_id)
  end

  def upsert_pending(instance_name, chat_id, chat_type, title) do
    case get(instance_name, chat_id) do
      %{status: "removed"} = existing ->
        existing |> changeset(%{status: "pending", info_sent: false, title: title}) |> Druzhok.Repo.update()
      nil ->
        %__MODULE__{} |> changeset(%{instance_name: instance_name, chat_id: chat_id, chat_type: chat_type, title: title}) |> Druzhok.Repo.insert()
      existing ->
        {:ok, existing}
    end
  end

  def approve(instance_name, chat_id) do
    case get(instance_name, chat_id) do
      nil -> {:error, :not_found}
      chat -> chat |> changeset(%{status: "approved"}) |> Druzhok.Repo.update()
    end
  end

  def reject(instance_name, chat_id) do
    case get(instance_name, chat_id) do
      nil -> {:error, :not_found}
      chat -> chat |> changeset(%{status: "rejected"}) |> Druzhok.Repo.update()
    end
  end

  def mark_removed(instance_name, chat_id) do
    case get(instance_name, chat_id) do
      nil -> :ok
      chat -> chat |> changeset(%{status: "removed"}) |> Druzhok.Repo.update()
    end
  end

  def mark_info_sent(instance_name, chat_id) do
    case get(instance_name, chat_id) do
      nil -> :ok
      chat -> chat |> changeset(%{info_sent: true}) |> Druzhok.Repo.update()
    end
  end

  def groups_for_instance(instance_name) do
    from(c in __MODULE__, where: c.instance_name == ^instance_name and c.chat_type != "private", order_by: c.inserted_at)
    |> Druzhok.Repo.all()
  end
end
```

- [ ] **Step 3: Create Pairing module**

```elixir
# v3/apps/druzhok/lib/druzhok/pairing.ex
defmodule Druzhok.Pairing do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  @alphabet ~c"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @code_length 8
  @ttl_seconds 3600

  schema "pairing_codes" do
    field :instance_name, :string
    field :code, :string
    field :telegram_user_id, :integer
    field :username, :string
    field :display_name, :string
    field :expires_at, :utc_datetime
    timestamps()
  end

  def changeset(pairing, attrs) do
    pairing
    |> cast(attrs, [:instance_name, :code, :telegram_user_id, :username, :display_name, :expires_at])
    |> validate_required([:instance_name, :code, :telegram_user_id, :expires_at])
    |> unique_constraint(:instance_name)
  end

  def get_pending(instance_name) do
    now = DateTime.utc_now()
    from(p in __MODULE__, where: p.instance_name == ^instance_name and p.expires_at > ^now)
    |> Druzhok.Repo.one()
  end

  def create_code(instance_name, telegram_user_id, username, display_name) do
    # Delete any expired codes first
    from(p in __MODULE__, where: p.instance_name == ^instance_name and p.expires_at <= ^DateTime.utc_now())
    |> Druzhok.Repo.delete_all()

    code = generate_code()
    expires_at = DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)

    %__MODULE__{}
    |> changeset(%{
      instance_name: instance_name,
      code: code,
      telegram_user_id: telegram_user_id,
      username: username,
      display_name: display_name,
      expires_at: expires_at,
    })
    |> Druzhok.Repo.insert(on_conflict: :replace_all, conflict_target: :instance_name)
  end

  def approve(instance_name) do
    case get_pending(instance_name) do
      nil -> {:error, :not_found}
      pairing ->
        # Set owner on instance
        case Druzhok.Repo.get_by(Druzhok.Instance, name: instance_name) do
          nil -> {:error, :instance_not_found}
          instance ->
            Druzhok.Repo.update(Druzhok.Instance.changeset(instance, %{owner_telegram_id: pairing.telegram_user_id}))
            Druzhok.Repo.delete(pairing)
            {:ok, pairing}
        end
    end
  end

  defp generate_code do
    for _ <- 1..@code_length, into: "" do
      <<Enum.random(@alphabet)>>
    end
  end
end
```

- [ ] **Step 4: Add `owner_telegram_id` to Instance schema**

In `v3/apps/druzhok/lib/druzhok/instance.ex`, add field and include in changeset cast list:

```elixir
field :owner_telegram_id, :integer
```

Add to cast: `[:name, :telegram_token, :model, :workspace, :active, :heartbeat_interval, :owner_telegram_id]`

- [ ] **Step 5: Run migration and verify**

Run: `cd v3 && mix ecto.migrate && mix compile`

- [ ] **Step 6: Commit**

```bash
git commit -m "add allowed_chats, pairing_codes tables and schemas"
```

---

### Task 2: WorkspaceLoader group flag + Session chat_id + idle timeout

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/workspace_loader.ex`
- Modify: `v3/apps/pi_core/lib/pi_core/session.ex`

- [ ] **Step 1: Update WorkspaceLoader to skip USER.md when `group: true`**

```elixir
# In Default.load/2, change:
def load(workspace, opts) do
  files = if opts[:group], do: @files -- ["USER.md"], else: @files
  files
  |> Enum.map(fn file -> ... end)
  # ... rest unchanged
end
```

- [ ] **Step 2: Add `chat_id` and `group` to Session struct**

Add `:chat_id` and `group: false` to the Session defstruct. In `init`, read from opts:

```elixir
chat_id: opts[:chat_id],
group: opts[:group] || false,
```

Pass `group` to workspace loader:
```elixir
system_prompt = loader.load(opts.workspace, %{group: opts[:group] || false})
```

- [ ] **Step 3: Include `chat_id` in `deliver_last_assistant`**

```elixir
defp deliver_last_assistant(new_messages, ref, state) do
  case Enum.find(Enum.reverse(new_messages), &(&1.role == "assistant")) do
    nil -> :ok
    msg ->
      pid = # ... existing Registry or caller lookup ...
      if pid, do: send(pid, {:pi_response, %{text: msg.content, prompt_id: ref, chat_id: state.chat_id}})
  end
end
```

Same for error delivery in `handle_info({:DOWN, ...})`.

- [ ] **Step 4: Add idle timeout**

```elixir
@idle_timeout_ms 2 * 60 * 60 * 1000  # 2 hours

# In init, after building state:
state = schedule_idle_timeout(state)

# In handle_cast({:prompt, ...}), reset timer:
state = schedule_idle_timeout(state)

# New handler:
def handle_info(:idle_timeout, state) do
  {:stop, :normal, state}
end

defp schedule_idle_timeout(state) do
  if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
  timer = Process.send_after(self(), :idle_timeout, @idle_timeout_ms)
  %{state | idle_timer: timer}
end
```

Add `:idle_timer` to the struct (default nil).

- [ ] **Step 5: Run tests**

Run: `cd v3 && mix test`
Expected: All existing tests pass

- [ ] **Step 6: Commit**

```bash
git commit -m "add group flag to workspace loader, chat_id and idle timeout to session"
```

---

### Task 3: Instance.Sup — SessionSup replacing single Session

**Files:**
- Create: `v3/apps/druzhok/lib/druzhok/instance/session_sup.ex`
- Modify: `v3/apps/druzhok/lib/druzhok/instance/sup.ex`

- [ ] **Step 1: Create SessionSup**

```elixir
defmodule Druzhok.Instance.SessionSup do
  use DynamicSupervisor

  def start_link(opts) do
    name = opts[:registry_name]
    if name do
      DynamicSupervisor.start_link(__MODULE__, opts, name: name)
    else
      DynamicSupervisor.start_link(__MODULE__, opts)
    end
  end

  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_session(instance_name, chat_id, session_opts) do
    case Registry.lookup(Druzhok.Registry, {instance_name, :session_sup}) do
      [{pid, _}] ->
        # Check if session already exists
        case Registry.lookup(Druzhok.Registry, {instance_name, :session, chat_id}) do
          [{existing, _}] -> {:ok, existing}
          [] ->
            opts = Map.merge(session_opts, %{
              name: {:via, Registry, {Druzhok.Registry, {instance_name, :session, chat_id}}},
              chat_id: chat_id,
            })
            DynamicSupervisor.start_child(pid, {PiCore.Session, opts})
        end
      [] -> {:error, :session_sup_not_found}
    end
  end
end
```

- [ ] **Step 2: Update Instance.Sup to use SessionSup instead of single Session**

Replace the `PiCore.Session` child with `Druzhok.Instance.SessionSup`. Move the Session config into a function that `start_session` can call later.

The `on_delta` closure now needs to include `chat_id`. Change its signature so Session can pass `chat_id` when calling it:

```elixir
on_delta = fn chunk, chat_id ->
  case Registry.lookup(Druzhok.Registry, {name, :telegram}) do
    [{pid, _}] -> send(pid, {:pi_delta, chunk, chat_id})
    [] -> :ok
  end
end
```

Store session config (model, api_url, api_key, workspace, on_delta, on_event, etc.) in a well-known place so `start_session` can use it — store in Registry metadata or in the Instance.Sup state. Simplest: store config in the Registry entry for `:session_sup`.

- [ ] **Step 3: Update Telegram to handle `{:pi_delta, chunk, chat_id}` and `{:pi_response, %{chat_id: ...}}`**

The Telegram bot now receives 3-element delta tuples and response maps with `chat_id`. Update:

```elixir
def handle_info({:pi_delta, chunk, chat_id}, state) when is_binary(chunk) do
  state = %{state | chat_id: chat_id}
  accumulated = (state.draft_text || "") <> chunk
  state = handle_streaming_delta(accumulated, %{state | draft_text: accumulated})
  {:noreply, state}
end

# Keep backward compat for old 2-element format
def handle_info({:pi_delta, chunk}, state) when is_binary(chunk) do
  # ... existing code
end

def handle_info({:pi_response, %{text: text, chat_id: chat_id}}, state) when is_binary(text) and text != "" do
  state = %{state | chat_id: chat_id}
  emit(state, :agent_reply, %{text: text})
  state = finalize_response(text, state)
  {:noreply, state}
end
```

- [ ] **Step 4: Update Session `on_delta` calls to pass `chat_id`**

In `run_prompt`, the `on_delta` from state is called by the LLM client. The client calls `on_delta.(chunk)` (1-arity). We need to wrap it:

```elixir
# In run_prompt, wrap on_delta to include chat_id:
wrapped_on_delta = if state.on_delta && state.chat_id do
  fn chunk -> state.on_delta.(chunk, state.chat_id) end
else
  state.on_delta
end
```

Then pass `wrapped_on_delta` to `Loop.run` instead of `state.on_delta`.

- [ ] **Step 5: Update all Session lookups from `{name, :session}` to `{name, :session, chat_id}`**

In `telegram.ex`: `dispatch_prompt` and `dispatch_session` now need `chat_id`:

```elixir
defp dispatch_prompt(text, chat_id, state) do
  case Registry.lookup(Druzhok.Registry, {state.instance_name, :session, chat_id}) do
    [{pid, _}] -> PiCore.Session.prompt(pid, text)
    [] ->
      # Session doesn't exist yet — start one
      start_session_for_chat(chat_id, state)
      # Retry lookup
      case Registry.lookup(Druzhok.Registry, {state.instance_name, :session, chat_id}) do
        [{pid, _}] -> PiCore.Session.prompt(pid, text)
        [] -> :ok
      end
  end
end
```

In `scheduler.ex`: heartbeat/reminder should go to the DM session. Need to know the owner's `chat_id`. Read `owner_telegram_id` from the instance DB record — the DM `chat_id` equals the owner's `telegram_user_id`.

- [ ] **Step 6: Run tests**

Run: `cd v3 && mix test`

- [ ] **Step 7: Commit**

```bash
git commit -m "replace single Session with per-chat SessionSup"
```

---

### Task 4: Telegram DM routing — pairing flow

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/agent/telegram.ex`

- [ ] **Step 1: Add bot identity on init**

Call `getMe` on init to get `bot_id` and `bot_username`. Read `IDENTITY.md` to extract bot name. Add fields to struct:

```elixir
:bot_id, :bot_username, :bot_name
```

In init (after `session_pid` is set or in a post-init Task):
```elixir
Task.start(fn ->
  case API.call(token, "getMe", %{}) do
    {:ok, %{"id" => id, "username" => username}} ->
      GenServer.cast(self, {:set_bot_info, id, username})
    _ -> :ok
  end
end)
```

Read IDENTITY.md for bot name:
```elixir
defp read_bot_name(workspace) do
  path = Path.join(workspace, "IDENTITY.md")
  case File.read(path) do
    {:ok, content} ->
      case Regex.run(~r/\*\*Имя:\*\*\s*(.+)/u, content) do
        [_, name] -> String.trim(name)
        _ -> nil
      end
    _ -> nil
  end
end
```

- [ ] **Step 2: Refactor `handle_update` into a routing layer**

Extract the current message handling into `route_message/4` that handles DM vs group:

```elixir
defp handle_update(%{"update_id" => update_id} = update, state) do
  state = %{state | offset: update_id + 1}
  case extract_message(update) do
    nil -> state
    {chat_id, chat_type, text, sender_id, sender_name, file} ->
      route_message(chat_id, chat_type, text, sender_id, sender_name, file, state)
  end
end

defp route_message(chat_id, "private", text, sender_id, sender_name, file, state) do
  handle_dm(chat_id, text, sender_id, sender_name, file, state)
end

defp route_message(chat_id, chat_type, text, sender_id, sender_name, file, state)
     when chat_type in ["group", "supergroup"] do
  handle_group(chat_id, text, sender_id, sender_name, file, state)
end

defp route_message(_chat_id, _chat_type, _text, _sender_id, _sender_name, _file, state), do: state
```

- [ ] **Step 3: Implement `handle_dm`**

```elixir
defp handle_dm(chat_id, text, sender_id, sender_name, file, state) do
  instance = Druzhok.Repo.get_by(Druzhok.Instance, name: state.instance_name)
  state = %{state | chat_id: chat_id, draft_message_id: nil, draft_text: nil, last_edit_at: nil}

  cond do
    # Owner exists and this is the owner
    instance && instance.owner_telegram_id == sender_id ->
      saved_file = if file, do: save_incoming_file(file, state), else: nil
      prompt_text = build_prompt(text, sender_name, saved_file)
      emit(state, :user_message, %{text: prompt_text, sender: sender_name, chat_id: chat_id})
      API.send_chat_action(state.token, chat_id)
      handle_command_or_prompt(text, prompt_text, chat_id, sender_id, state)

    # Owner exists but this is someone else
    instance && instance.owner_telegram_id ->
      emit(state, :dm_rejected, %{text: "Rejected DM from #{sender_name}"})
      API.send_message(state.token, chat_id, "This bot is private.")
      state

    # No owner — check pairing
    true ->
      handle_pairing(chat_id, sender_id, sender_name, state)
  end
end
```

- [ ] **Step 4: Implement `handle_pairing`**

```elixir
defp handle_pairing(chat_id, sender_id, sender_name, state) do
  case Druzhok.Pairing.get_pending(state.instance_name) do
    %{telegram_user_id: ^sender_id, code: code} ->
      # Same user — re-send code
      API.send_message(state.token, chat_id, "Your activation code: #{code}\nEnter it in the dashboard.")
      state

    %{} ->
      # Different user — pairing in progress
      API.send_message(state.token, chat_id, "This bot is not available.")
      state

    nil ->
      # No pending pairing — create one
      {:ok, pairing} = Druzhok.Pairing.create_code(state.instance_name, sender_id, nil, sender_name)
      emit(state, :pairing_requested, %{text: "Pairing code: #{pairing.code}", code: pairing.code, user: sender_name})
      API.send_message(state.token, chat_id, "Your activation code: #{pairing.code}\nEnter it in the dashboard.")
      state
  end
end
```

- [ ] **Step 5: Extract `handle_command_or_prompt` from current command logic**

Move the existing `/start`, `/reset`, `/abort`, `:text` handling into this function. Pass `chat_id` to dispatch functions.

- [ ] **Step 6: Update `extract_message` to return `chat_type` and `sender_id`**

```elixir
defp extract_message(%{"message" => msg}) do
  from = msg["from"]
  if from && !from["is_bot"] do
    chat_id = msg["chat"]["id"]
    chat_type = msg["chat"]["type"] || "private"
    text = msg["text"] || msg["caption"] || ""
    sender_id = from["id"]
    name = [from["first_name"], from["last_name"]] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
    file = extract_file(msg)
    {chat_id, chat_type, text, sender_id, name, file}
  else
    nil
  end
end
```

- [ ] **Step 7: Run tests**

Run: `cd v3 && mix test`

- [ ] **Step 8: Commit**

```bash
git commit -m "add DM pairing flow and routing layer"
```

---

### Task 5: Telegram group routing — triggers + approval

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/agent/telegram.ex`

- [ ] **Step 1: Implement `handle_group`**

```elixir
defp handle_group(chat_id, text, sender_id, sender_name, file, state) do
  chat = Druzhok.AllowedChat.get(state.instance_name, chat_id)

  cond do
    chat && chat.status == "approved" ->
      if triggered?(text, state) do
        state = %{state | chat_id: chat_id, draft_message_id: nil, draft_text: nil, last_edit_at: nil}
        saved_file = if file, do: save_incoming_file(file, state), else: nil
        prompt_text = build_prompt(text, sender_name, saved_file)
        emit(state, :user_message, %{text: prompt_text, sender: sender_name, chat_id: chat_id})
        API.send_chat_action(state.token, chat_id)
        handle_command_or_prompt(text, prompt_text, chat_id, sender_id, state)
      else
        state
      end

    chat && chat.status == "rejected" ->
      state

    true ->
      # Pending or unknown — create pending record
      Druzhok.AllowedChat.upsert_pending(state.instance_name, chat_id, "group", nil)
      emit(state, :group_pending, %{text: "Group pending: #{chat_id}"})

      # Send info message once if @mentioned
      if mentioned_by_username?(text, state) && (is_nil(chat) || !chat.info_sent) do
        API.send_message(state.token, chat_id, "This bot requires approval. Ask the admin to approve this group in the dashboard.")
        Druzhok.AllowedChat.mark_info_sent(state.instance_name, chat_id)
      end

      state
  end
end
```

- [ ] **Step 2: Implement trigger detection**

```elixir
defp triggered?(text, state) do
  mentioned_by_username?(text, state) ||
  replied_to_bot?(text, state) ||
  name_mentioned?(text, state)
end

defp mentioned_by_username?(text, %{bot_username: nil}), do: false
defp mentioned_by_username?(text, %{bot_username: username}) do
  String.contains?(String.downcase(text), "@" <> String.downcase(username))
end

defp replied_to_bot?(_text, _state) do
  # This needs the full update, not just text — handle in extract_message
  # by extracting reply_to_message.from.id
  false
end

defp name_mentioned?(_text, %{bot_name: nil}), do: false
defp name_mentioned?(text, %{bot_name: name}) do
  pattern = ~r/\b#{Regex.escape(name)}\b/iu
  Regex.match?(pattern, text)
end
```

Note: `replied_to_bot?` needs the reply_to_message from the update. Add `reply_to_bot_id` to the extracted message tuple, or check it during extraction.

- [ ] **Step 3: Update `extract_message` to detect reply-to-bot**

Add a `reply_to_bot` boolean to the returned tuple by checking `msg["reply_to_message"]["from"]["id"] == bot_id`. Pass through the routing layer.

- [ ] **Step 4: Restrict commands in groups**

In `handle_command_or_prompt`, when in a group context, check if `sender_id == instance.owner_telegram_id` for `/reset` and `/abort`. If not owner, ignore the command silently.

- [ ] **Step 5: Handle group sessions with `group: true`**

When starting a session for a group chat, pass `group: true` so WorkspaceLoader skips USER.md:

```elixir
defp start_session_for_chat(chat_id, state, group: true) do
  Druzhok.Instance.SessionSup.start_session(state.instance_name, chat_id, %{
    workspace: workspace,
    model: model,
    group: true,
    # ... other opts
  })
end
```

- [ ] **Step 6: Run tests**

Run: `cd v3 && mix test`

- [ ] **Step 7: Commit**

```bash
git commit -m "add group chat routing, triggers, and approval logic"
```

---

### Task 6: InstanceManager — pairing + group approval APIs

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/instance_manager.ex`

- [ ] **Step 1: Add pairing and group management functions**

```elixir
def approve_pairing(instance_name) do
  case Druzhok.Pairing.approve(instance_name) do
    {:ok, pairing} ->
      Druzhok.Events.broadcast(instance_name, %{type: :pairing_approved, user: pairing.display_name})
      {:ok, pairing}
    error -> error
  end
end

def approve_group(instance_name, chat_id) do
  case Druzhok.AllowedChat.approve(instance_name, chat_id) do
    {:ok, chat} ->
      Druzhok.Events.broadcast(instance_name, %{type: :group_approved, title: chat.title})
      {:ok, chat}
    error -> error
  end
end

def reject_group(instance_name, chat_id) do
  case Druzhok.AllowedChat.reject(instance_name, chat_id) do
    {:ok, chat} ->
      Druzhok.Events.broadcast(instance_name, %{type: :group_rejected, title: chat.title})
      # Terminate group session if running
      case Registry.lookup(Druzhok.Registry, {instance_name, :session, chat_id}) do
        [{pid, _}] -> GenServer.stop(pid, :normal, 5_000)
        [] -> :ok
      end
      {:ok, chat}
    error -> error
  end
end

def get_pairing(instance_name) do
  Druzhok.Pairing.get_pending(instance_name)
end

def get_groups(instance_name) do
  Druzhok.AllowedChat.groups_for_instance(instance_name)
end

def get_owner(instance_name) do
  case Druzhok.Repo.get_by(Druzhok.Instance, name: instance_name) do
    nil -> nil
    inst -> inst.owner_telegram_id
  end
end
```

- [ ] **Step 2: Run tests**

Run: `cd v3 && mix test`

- [ ] **Step 3: Commit**

```bash
git commit -m "add pairing and group approval APIs to InstanceManager"
```

---

### Task 7: Dashboard — Security tab

**Files:**
- Modify: `v3/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex`

- [ ] **Step 1: Add "Security" tab alongside Logs and Files**

Add a third tab button. When selected, shows:
- **Pairing section** (if no owner): pending code, user info, Approve button
- **Owner section** (if owner set): display name, telegram_user_id
- **Groups section**: list with status badges, Approve/Reject buttons

- [ ] **Step 2: Add event handlers**

```elixir
def handle_event("approve_pairing", %{"name" => name}, socket) do
  Druzhok.InstanceManager.approve_pairing(name)
  {:noreply, assign(socket, instances: list_instances())}
end

def handle_event("approve_group", %{"name" => name, "chat_id" => chat_id}, socket) do
  Druzhok.InstanceManager.approve_group(name, String.to_integer(chat_id))
  {:noreply, socket}
end

def handle_event("reject_group", %{"name" => name, "chat_id" => chat_id}, socket) do
  Druzhok.InstanceManager.reject_group(name, String.to_integer(chat_id))
  {:noreply, socket}
end
```

- [ ] **Step 3: Load security data in mount/handle_params**

When an instance is selected, load pairing + groups + owner info into assigns.

- [ ] **Step 4: Run tests**

Run: `cd v3 && mix test`

- [ ] **Step 5: Commit**

```bash
git commit -m "add Security tab with pairing approval and group management"
```

---

### Task 8: Integration tests

**Files:**
- Create: `v3/apps/druzhok/test/druzhok/group_chat_test.exs`

- [ ] **Step 1: Write pairing tests**

Test code generation, same-user resend, second-user rejection, approval sets owner, expired code cleanup.

- [ ] **Step 2: Write group approval tests**

Test pending record creation, approval, rejection, removed status.

- [ ] **Step 3: Write trigger detection tests**

Test @mention, reply-to-bot, name detection, non-triggered message ignored.

- [ ] **Step 4: Write session isolation tests**

Test that two group sessions have independent conversation histories, USER.md skipped in groups.

- [ ] **Step 5: Run full test suite**

Run: `cd v3 && mix test`

- [ ] **Step 6: Commit**

```bash
git commit -m "add group chat integration tests"
```

---

### Task 9: Manual smoke test

- [ ] **Step 1: Restart server**

```bash
ps aux | grep beam | grep -v grep | awk '{print $2}' | xargs kill
sleep 2
source v2/.env && export NEBIUS_API_KEY NEBIUS_BASE_URL ANTHROPIC_API_KEY
cd v3 && mix ecto.migrate && mix phx.server
```

- [ ] **Step 2: Test DM pairing flow**

Message the bot from Telegram → get pairing code → approve in dashboard → verify owner set

- [ ] **Step 3: Test DM rejection**

Message bot from a different Telegram account → verify "This bot is private."

- [ ] **Step 4: Test group chat**

Add bot to a group → verify appears as pending in dashboard → approve → @mention bot → verify response

- [ ] **Step 5: Test triggers**

In approved group: test @mention, reply to bot message, mention bot name in text

- [ ] **Step 6: Final commit**

```bash
git commit -m "group chats: complete implementation"
```
