# Group Chat Message Buffer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace per-message LLM calls in group chats with a buffer pattern — non-triggered messages are stored in ETS and only sent as context when the bot is actually addressed, reducing LLM calls by 90-98%.

**Architecture:** A `GroupBuffer` ETS module buffers non-triggered group messages. Two activation modes per group (`buffer`/`always`) control whether messages go to the LLM or the buffer. Mode is configurable via dashboard and `/mode` bot command.

**Tech Stack:** Elixir/OTP, ETS, Phoenix LiveView, Ecto/SQLite

**Spec:** `docs/superpowers/specs/2026-03-23-group-buffer-design.md`

---

## File Structure

### New files
- `v3/apps/druzhok/lib/druzhok/group_buffer.ex` — ETS-backed message buffer
- `v3/apps/druzhok/test/druzhok/group_buffer_test.exs`
- `v3/apps/druzhok/priv/repo/migrations/20260323000002_add_activation_to_allowed_chats.exs`

### Modified files
- `v3/apps/druzhok/lib/druzhok/application.ex` — create ETS table on start
- `v3/apps/druzhok/lib/druzhok/allowed_chat.ex` — add `activation`, `buffer_size` fields; clear buffer on reject/remove
- `v3/apps/druzhok/lib/druzhok/agent/router.ex` — add `/mode` command parsing with argument
- `v3/apps/druzhok/lib/druzhok/agent/telegram.ex` — route messages through buffer in buffer mode
- `v3/apps/druzhok_web/lib/druzhok_web_web/live/components/security_tab.ex` — add activation/buffer_size controls

---

### Task 1: GroupBuffer module

**Files:**
- Create: `v3/apps/druzhok/lib/druzhok/group_buffer.ex`
- Create: `v3/apps/druzhok/test/druzhok/group_buffer_test.exs`
- Modify: `v3/apps/druzhok/lib/druzhok/application.ex`

- [ ] **Step 1: Write the failing tests**

```elixir
# v3/apps/druzhok/test/druzhok/group_buffer_test.exs
defmodule Druzhok.GroupBufferTest do
  use ExUnit.Case

  alias Druzhok.GroupBuffer

  setup do
    # Ensure table exists (application.ex creates it, but in test we may need to handle it)
    if :ets.whereis(:druzhok_group_buffer) == :undefined do
      :ets.new(:druzhok_group_buffer, [:set, :public, :named_table])
    end
    # Clear any existing data for our test keys
    GroupBuffer.clear("test_bot", 12345)
    GroupBuffer.clear("test_bot", 99999)
    :ok
  end

  test "push and flush returns messages in order" do
    GroupBuffer.push("test_bot", 12345, %{sender: "Alice", text: "hello", timestamp: 1000, file: nil}, 50)
    GroupBuffer.push("test_bot", 12345, %{sender: "Bob", text: "hi there", timestamp: 2000, file: nil}, 50)

    messages = GroupBuffer.flush("test_bot", 12345)
    assert length(messages) == 2
    assert Enum.at(messages, 0).sender == "Alice"
    assert Enum.at(messages, 1).sender == "Bob"
  end

  test "flush clears the buffer" do
    GroupBuffer.push("test_bot", 12345, %{sender: "Alice", text: "hello", timestamp: 1000, file: nil}, 50)
    _messages = GroupBuffer.flush("test_bot", 12345)

    assert GroupBuffer.flush("test_bot", 12345) == []
    assert GroupBuffer.size("test_bot", 12345) == 0
  end

  test "push trims oldest when over max_size" do
    for i <- 1..10 do
      GroupBuffer.push("test_bot", 12345, %{sender: "User", text: "msg #{i}", timestamp: i, file: nil}, 5)
    end

    assert GroupBuffer.size("test_bot", 12345) == 5
    messages = GroupBuffer.flush("test_bot", 12345)
    # Should have messages 6-10 (oldest trimmed)
    assert Enum.at(messages, 0).text == "msg 6"
    assert Enum.at(messages, 4).text == "msg 10"
  end

  test "clear removes all messages" do
    GroupBuffer.push("test_bot", 12345, %{sender: "Alice", text: "hello", timestamp: 1000, file: nil}, 50)
    GroupBuffer.clear("test_bot", 12345)
    assert GroupBuffer.size("test_bot", 12345) == 0
  end

  test "size returns 0 for empty buffer" do
    assert GroupBuffer.size("test_bot", 99999) == 0
  end

  test "different instance_names are isolated" do
    GroupBuffer.push("bot_a", 12345, %{sender: "Alice", text: "from A", timestamp: 1000, file: nil}, 50)
    GroupBuffer.push("bot_b", 12345, %{sender: "Bob", text: "from B", timestamp: 1000, file: nil}, 50)

    a_msgs = GroupBuffer.flush("bot_a", 12345)
    b_msgs = GroupBuffer.flush("bot_b", 12345)
    assert length(a_msgs) == 1
    assert length(b_msgs) == 1
    assert Enum.at(a_msgs, 0).text == "from A"
    assert Enum.at(b_msgs, 0).text == "from B"
  end

  test "format_context builds readable chat log" do
    messages = [
      %{sender: "Иван", text: "привет всем", timestamp: 1000, file: nil},
      %{sender: "Мария", text: "кто идёт?", timestamp: 2000, file: nil},
    ]
    current = "[Мария]: @bot что думаешь?\n[обращение к тебе — ответ обязателен]"

    result = GroupBuffer.format_context(messages, current)
    assert result =~ "Сообщения в чате"
    assert result =~ "[Иван]: привет всем"
    assert result =~ "[Мария]: кто идёт?"
    assert result =~ "Текущее сообщение"
    assert result =~ "@bot что думаешь?"
  end

  test "format_context with empty buffer returns just the current message" do
    result = GroupBuffer.format_context([], "hello")
    assert result == "hello"
  end
end
```

- [ ] **Step 2: Create ETS table in application.ex**

In `v3/apps/druzhok/lib/druzhok/application.ex`, add after the `def start` line, before `children`:

```elixir
# Create ETS table for group message buffer
:ets.new(:druzhok_group_buffer, [:set, :public, :named_table])
```

- [ ] **Step 3: Write the implementation**

```elixir
# v3/apps/druzhok/lib/druzhok/group_buffer.ex
defmodule Druzhok.GroupBuffer do
  @moduledoc """
  ETS-backed buffer for non-triggered group chat messages.
  Messages are stored per {instance_name, chat_id} and flushed
  as context when the bot is triggered.
  """

  @table :druzhok_group_buffer

  @doc "Push a message to the buffer, trimming oldest if over max_size."
  def push(instance_name, chat_id, message, max_size) do
    key = {instance_name, chat_id}
    existing = case :ets.lookup(@table, key) do
      [{^key, msgs}] -> msgs
      [] -> []
    end

    updated = existing ++ [message]
    trimmed = if length(updated) > max_size do
      Enum.drop(updated, length(updated) - max_size)
    else
      updated
    end

    :ets.insert(@table, {key, trimmed})
    :ok
  end

  @doc "Return all buffered messages and clear the buffer."
  def flush(instance_name, chat_id) do
    key = {instance_name, chat_id}
    case :ets.lookup(@table, key) do
      [{^key, msgs}] ->
        :ets.delete(@table, key)
        msgs
      [] ->
        []
    end
  end

  @doc "Discard buffer without returning."
  def clear(instance_name, chat_id) do
    :ets.delete(@table, {instance_name, chat_id})
    :ok
  end

  @doc "Current buffer length."
  def size(instance_name, chat_id) do
    case :ets.lookup(@table, {instance_name, chat_id}) do
      [{_, msgs}] -> length(msgs)
      [] -> 0
    end
  end

  @doc """
  Format buffered messages as a context block prepended to the current message.
  Returns just the current message if the buffer is empty.
  """
  def format_context([], current_message), do: current_message
  def format_context(buffered_messages, current_message) do
    history = Enum.map_join(buffered_messages, "\n", fn msg ->
      base = "[#{msg.sender}]: #{msg.text}"
      if msg.file, do: base <> "\n[attached: #{msg.file}]", else: base
    end)

    """
    [Сообщения в чате с момента твоего последнего ответа — для контекста]
    #{history}

    [Текущее сообщение — ответь на него]
    #{current_message}\
    """
  end
end
```

- [ ] **Step 4: Run tests**

Run: `cd v3 && mix test apps/druzhok/test/druzhok/group_buffer_test.exs`
Expected: all PASS

- [ ] **Step 5: Commit**

Message: `add GroupBuffer ETS module for group message buffering`

---

### Task 2: Database migration and AllowedChat schema update

**Files:**
- Create: `v3/apps/druzhok/priv/repo/migrations/20260323000002_add_activation_to_allowed_chats.exs`
- Modify: `v3/apps/druzhok/lib/druzhok/allowed_chat.ex`

- [ ] **Step 1: Create migration**

```elixir
# v3/apps/druzhok/priv/repo/migrations/20260323000002_add_activation_to_allowed_chats.exs
defmodule Druzhok.Repo.Migrations.AddActivationToAllowedChats do
  use Ecto.Migration

  def change do
    alter table(:allowed_chats) do
      add :activation, :string, default: "buffer"
      add :buffer_size, :integer, default: 50
    end
  end
end
```

- [ ] **Step 2: Run migration**

Run: `cd v3 && mix ecto.migrate`

- [ ] **Step 3: Update AllowedChat schema**

In `v3/apps/druzhok/lib/druzhok/allowed_chat.ex`:

Add to schema block after `field :info_sent`:
```elixir
field :activation, :string, default: "buffer"
field :buffer_size, :integer, default: 50
```

Update changeset to cast new fields:
```elixir
|> cast(attrs, [:instance_name, :chat_id, :chat_type, :title, :telegram_user_id, :status, :info_sent, :activation, :buffer_size])
```

Add buffer cleanup to `reject/2` and `mark_removed/2`:
```elixir
def reject(instance_name, chat_id) do
  Druzhok.GroupBuffer.clear(instance_name, chat_id)
  case get(instance_name, chat_id) do
    nil -> {:error, :not_found}
    chat -> chat |> changeset(%{status: "rejected"}) |> Druzhok.Repo.update()
  end
end

def mark_removed(instance_name, chat_id) do
  Druzhok.GroupBuffer.clear(instance_name, chat_id)
  case get(instance_name, chat_id) do
    nil -> :ok
    chat -> chat |> changeset(%{status: "removed"}) |> Druzhok.Repo.update()
  end
end
```

Add helper to update activation:
```elixir
def set_activation(instance_name, chat_id, activation) when activation in ["buffer", "always"] do
  case get(instance_name, chat_id) do
    nil -> {:error, :not_found}
    chat -> chat |> changeset(%{activation: activation}) |> Druzhok.Repo.update()
  end
end
```

- [ ] **Step 4: Verify compilation**

Run: `cd v3 && mix compile`

- [ ] **Step 5: Commit**

Message: `add activation and buffer_size to allowed_chats`

---

### Task 3: Router — add /mode command parsing

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/agent/router.ex`

- [ ] **Step 1: Update parse_command to support arguments**

In `v3/apps/druzhok/lib/druzhok/agent/router.ex`, replace the parse_command functions:

```elixir
@doc """
Parse a command from message text.

Returns `{:command, name}`, `{:command, name, arg}`, or `:text`.
"""
def parse_command("/start" <> _), do: {:command, "start"}
def parse_command("/reset" <> _), do: {:command, "reset"}
def parse_command("/abort" <> _), do: {:command, "abort"}
def parse_command("/mode " <> arg), do: {:command, "mode", String.trim(arg)}
def parse_command("/mode"), do: {:command, "mode", ""}
def parse_command("/" <> _), do: :text
def parse_command(_), do: :text
```

Note: The `/mode` clauses MUST come before the catch-all `"/" <> _` clause.

- [ ] **Step 2: Verify no regressions**

Run: `cd v3 && mix test apps/pi_core/test/ apps/druzhok/test/`
Expected: all existing tests PASS

- [ ] **Step 3: Commit**

Message: `add /mode command parsing to Router`

---

### Task 4: Telegram — route group messages through buffer

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/agent/telegram.ex`

This is the core change. The `process_group_message/7` function needs to branch on activation mode.

- [ ] **Step 1: Update process_group_message**

In `v3/apps/druzhok/lib/druzhok/agent/telegram.ex`, replace the `process_group_message` function (lines 373-405) with:

```elixir
# Group messages: route based on activation mode
defp process_group_message(chat_id, text, sender_id, sender_name, file, is_triggered, state) do
  is_owner = state.owner_telegram_id == sender_id
  chat = Druzhok.AllowedChat.get(state.instance_name, chat_id)
  activation = (chat && chat.activation) || "buffer"
  buffer_size = (chat && chat.buffer_size) || 50

  # Commands always processed (regardless of mode)
  case Router.parse_command(text) do
    {:command, "reset"} when is_owner ->
      dispatch_session(chat_id, state, &PiCore.Session.reset/1)
      Druzhok.GroupBuffer.clear(state.instance_name, chat_id)
      API.send_message(state.token, chat_id, "Session reset!")
      state

    {:command, "abort"} when is_owner ->
      dispatch_session(chat_id, state, &PiCore.Session.abort/1)
      API.send_message(state.token, chat_id, "Aborted.")
      state

    {:command, "mode", arg} when is_owner ->
      handle_mode_command(arg, chat_id, state)

    {:command, "start"} ->
      prompt = "[#{sender_name} started the bot in group chat]"
      dispatch_prompt(prompt, chat_id, true, state)
      state

    _ ->
      case activation do
        "always" ->
          # Current behavior: every message goes to LLM
          process_group_message_always(chat_id, text, sender_name, file, is_triggered, state)

        _ ->
          # Buffer mode: only triggered messages go to LLM
          process_group_message_buffer(chat_id, text, sender_name, file, is_triggered, buffer_size, state)
      end
  end
end

defp process_group_message_always(chat_id, text, sender_name, file, is_triggered, state) do
  saved_file = if file, do: save_incoming_file(file, chat_id, state), else: nil
  prompt = build_group_prompt(text, sender_name, saved_file, is_triggered)
  emit(state, :user_message, %{text: prompt, sender: sender_name, chat_id: chat_id})

  if is_triggered do
    API.send_chat_action(state.token, chat_id)
  end

  dispatch_prompt(prompt, chat_id, true, state)
  state
end

defp process_group_message_buffer(chat_id, text, sender_name, file, is_triggered, buffer_size, state) do
  if is_triggered do
    # Flush buffer and send as context
    saved_file = if file, do: save_incoming_file(file, chat_id, state), else: nil
    buffered = Druzhok.GroupBuffer.flush(state.instance_name, chat_id)
    current_prompt = build_group_prompt(text, sender_name, saved_file, true)
    prompt = Druzhok.GroupBuffer.format_context(buffered, current_prompt)

    emit(state, :user_message, %{text: current_prompt, sender: sender_name, chat_id: chat_id})
    API.send_chat_action(state.token, chat_id)
    dispatch_prompt(prompt, chat_id, true, state)
    state
  else
    # Buffer the message, no LLM call
    file_ref = if file, do: "[#{file.name || "file"}]", else: nil
    Druzhok.GroupBuffer.push(state.instance_name, chat_id, %{
      sender: sender_name,
      text: text,
      timestamp: System.os_time(:millisecond),
      file: file_ref
    }, buffer_size)

    emit(state, :user_message, %{text: "[#{sender_name}]: #{text}", sender: sender_name, chat_id: chat_id, buffered: true})
    state
  end
end

defp handle_mode_command(arg, chat_id, state) do
  case arg do
    mode when mode in ["buffer", "always"] ->
      Druzhok.AllowedChat.set_activation(state.instance_name, chat_id, mode)
      if mode == "buffer", do: Druzhok.GroupBuffer.clear(state.instance_name, chat_id)
      label = if mode == "buffer", do: "buffer (respond only when addressed)", else: "always (see all messages)"
      API.send_message(state.token, chat_id, "Mode: #{label}")
      state

    _ ->
      chat = Druzhok.AllowedChat.get(state.instance_name, chat_id)
      current = (chat && chat.activation) || "buffer"
      API.send_message(state.token, chat_id, "Current mode: #{current}\nUsage: /mode buffer | /mode always")
      state
  end
end
```

- [ ] **Step 2: Update handle_group to pass the new arity**

The `handle_group` function at line 348 calls `process_group_message/7`. The new version still takes 7 args (chat_id, text, sender_id, sender_name, file, is_triggered, state), so no signature change needed. But verify `chat` is no longer fetched inside `process_group_message` since `handle_group` already fetches it — actually the new version re-fetches it to get activation. This is fine (one extra DB read per group message, but it's a simple key lookup).

- [ ] **Step 3: Also clear buffer on /reset**

Already included in the new `process_group_message` — the reset branch calls `Druzhok.GroupBuffer.clear(state.instance_name, chat_id)`.

- [ ] **Step 4: Run tests**

Run: `cd v3 && mix test`
Expected: all existing tests PASS

- [ ] **Step 5: Manual test (if bot is running)**

1. Add bot to a test group, approve it
2. Send messages without mentioning bot — should NOT get responses
3. Mention the bot — should get a response with context from buffered messages
4. Run `/mode always` — every message should get LLM response
5. Run `/mode buffer` — back to buffer mode

- [ ] **Step 6: Commit**

Message: `route group messages through buffer in buffer activation mode`

---

### Task 5: Dashboard — activation controls in SecurityTab

**Files:**
- Modify: `v3/apps/druzhok_web/lib/druzhok_web_web/live/components/security_tab.ex`
- Modify: `v3/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex` (handle new events)

- [ ] **Step 1: Update SecurityTab component**

In `v3/apps/druzhok_web/lib/druzhok_web_web/live/components/security_tab.ex`, replace the group row for approved groups (line 56) with controls:

Replace the single "Approved" span with activation controls:

```heex
<div :if={group.status == "approved"} class="flex items-center gap-2">
  <select phx-change="update_group_activation" phx-value-name={@instance_name} phx-value-chat_id={group.chat_id}
          name="activation" class="text-xs border border-gray-300 rounded px-2 py-1">
    <option value="buffer" selected={group.activation == "buffer"}>Buffer</option>
    <option value="always" selected={group.activation == "always"}>Always</option>
  </select>
  <input type="number" phx-blur="update_group_buffer_size" phx-value-name={@instance_name} phx-value-chat_id={group.chat_id}
         name="buffer_size" value={group.buffer_size || 50} min="1" max="500"
         class="w-16 text-xs border border-gray-300 rounded px-2 py-1 font-mono" />
</div>
```

- [ ] **Step 2: Handle events in DashboardLive**

Read `v3/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex` to find where group events are handled. Add these handlers:

```elixir
def handle_event("update_group_activation", %{"name" => name, "chat_id" => chat_id, "activation" => activation}, socket) do
  chat_id = String.to_integer(chat_id)
  Druzhok.AllowedChat.set_activation(name, chat_id, activation)
  if activation == "buffer", do: Druzhok.GroupBuffer.clear(name, chat_id)
  groups = Druzhok.AllowedChat.groups_for_instance(name)
  {:noreply, assign(socket, groups: groups)}
end

def handle_event("update_group_buffer_size", %{"name" => name, "chat_id" => chat_id, "value" => size}, socket) do
  chat_id = String.to_integer(chat_id)
  size = size |> String.to_integer() |> max(1) |> min(500)
  case Druzhok.AllowedChat.get(name, chat_id) do
    nil -> :ok
    chat -> Druzhok.AllowedChat.changeset(chat, %{buffer_size: size}) |> Druzhok.Repo.update()
  end
  groups = Druzhok.AllowedChat.groups_for_instance(name)
  {:noreply, assign(socket, groups: groups)}
end
```

- [ ] **Step 3: Verify the page loads**

Run: `cd v3 && mix compile`
Expected: clean compilation

- [ ] **Step 4: Commit**

Message: `add activation mode controls to security tab`

---

### Task 6: Full test run and cleanup

- [ ] **Step 1: Run full test suite**

Run: `cd v3 && mix test`
Expected: all pass (except pre-existing Docker timeout failures)

- [ ] **Step 2: Check for compiler warnings**

Run: `cd v3 && mix compile --warnings-as-errors 2>&1 | grep "warning:" | grep -v "apps/data\|Reminder\|catch.*rescue\|unused.*data\|never match"`
Expected: no new warnings from our code

- [ ] **Step 3: Commit if any cleanup needed**

Message: `fix warnings from group buffer implementation`
