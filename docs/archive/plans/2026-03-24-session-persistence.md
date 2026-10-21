# Session Persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist session messages to per-chat JSONL files so conversations survive deploys and restarts.

**Architecture:** `SessionStore` gets per-chat file paths (`sessions/<chat_id>.jsonl`) with a 500-message cap. `Session` calls `load` on init, `append_many` after each turn, `save` after compaction.

**Tech Stack:** Elixir/OTP, ExUnit

**Spec:** `docs/superpowers/specs/2026-03-24-session-persistence-design.md`

---

## File Structure

### Modified files
- `v3/apps/pi_core/lib/pi_core/session_store.ex` — per-chat paths, 500 cap, append_many
- `v3/apps/pi_core/lib/pi_core/session.ex` — load on init, append after turn, save after compaction
- `v3/apps/pi_core/test/pi_core/session_store_test.exs` — update tests for new API

---

### Task 1: Update SessionStore with per-chat API

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/session_store.ex`
- Modify: `v3/apps/pi_core/test/pi_core/session_store_test.exs`

- [ ] **Step 1: Write failing tests**

Read the existing `v3/apps/pi_core/test/pi_core/session_store_test.exs` first. Replace with tests for the new per-chat API:

```elixir
defmodule PiCore.SessionStoreTest do
  use ExUnit.Case

  alias PiCore.SessionStore
  alias PiCore.Loop.Message

  @workspace System.tmp_dir!() |> Path.join("session_store_test_#{:rand.uniform(99999)}")

  setup do
    File.rm_rf!(@workspace)
    File.mkdir_p!(@workspace)
    on_exit(fn -> File.rm_rf!(@workspace) end)
    :ok
  end

  test "save and load round-trip" do
    messages = [
      %Message{role: "user", content: "hello", timestamp: 1},
      %Message{role: "assistant", content: "hi", timestamp: 2}
    ]
    SessionStore.save(@workspace, 12345, messages)
    loaded = SessionStore.load(@workspace, 12345)
    assert length(loaded) == 2
    assert Enum.at(loaded, 0)["role"] == "user"
    assert Enum.at(loaded, 0)["content"] == "hello"
    assert Enum.at(loaded, 1)["role"] == "assistant"
  end

  test "load returns empty list when no file" do
    assert SessionStore.load(@workspace, 99999) == []
  end

  test "append_many adds messages to existing file" do
    msg1 = %Message{role: "user", content: "first", timestamp: 1}
    SessionStore.save(@workspace, 100, [msg1])

    new_msgs = [
      %Message{role: "assistant", content: "reply", timestamp: 2},
      %Message{role: "user", content: "second", timestamp: 3}
    ]
    SessionStore.append_many(@workspace, 100, new_msgs)

    loaded = SessionStore.load(@workspace, 100)
    assert length(loaded) == 3
  end

  test "append_many creates file if not exists" do
    msgs = [%Message{role: "user", content: "hi", timestamp: 1}]
    SessionStore.append_many(@workspace, 200, msgs)
    loaded = SessionStore.load(@workspace, 200)
    assert length(loaded) == 1
  end

  test "save enforces 500 message cap" do
    messages = for i <- 1..600 do
      %Message{role: "user", content: "msg #{i}", timestamp: i}
    end
    SessionStore.save(@workspace, 300, messages)
    loaded = SessionStore.load(@workspace, 300)
    assert length(loaded) == 500
    # Should keep most recent 500 (101-600)
    assert Enum.at(loaded, 0)["content"] == "msg 101"
    assert Enum.at(loaded, 499)["content"] == "msg 600"
  end

  test "clear deletes per-chat file" do
    SessionStore.save(@workspace, 400, [%Message{role: "user", content: "bye", timestamp: 1}])
    SessionStore.clear(@workspace, 400)
    assert SessionStore.load(@workspace, 400) == []
  end

  test "different chat_ids are isolated" do
    SessionStore.save(@workspace, 1, [%Message{role: "user", content: "chat1", timestamp: 1}])
    SessionStore.save(@workspace, 2, [%Message{role: "user", content: "chat2", timestamp: 1}])

    loaded1 = SessionStore.load(@workspace, 1)
    loaded2 = SessionStore.load(@workspace, 2)
    assert Enum.at(loaded1, 0)["content"] == "chat1"
    assert Enum.at(loaded2, 0)["content"] == "chat2"
  end

  test "creates sessions/ directory on first write" do
    refute File.dir?(Path.join(@workspace, "sessions"))
    SessionStore.save(@workspace, 500, [%Message{role: "user", content: "hi", timestamp: 1}])
    assert File.dir?(Path.join(@workspace, "sessions"))
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/session_store_test.exs`
Expected: failures (API changed)

- [ ] **Step 3: Rewrite SessionStore**

```elixir
defmodule PiCore.SessionStore do
  @max_messages 500

  def save(workspace, chat_id, messages) do
    path = session_path(workspace, chat_id)
    ensure_dir(path)
    capped = cap_messages(messages)
    content = capped |> Enum.map(&encode_message/1) |> Enum.join("\n")
    File.write!(path, content <> "\n")
  end

  def append_many(workspace, chat_id, messages) do
    path = session_path(workspace, chat_id)
    ensure_dir(path)
    content = messages |> Enum.map(&encode_message/1) |> Enum.join("\n")
    File.write!(path, content <> "\n", [:append])
  end

  def load(workspace, chat_id) do
    path = session_path(workspace, chat_id)
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&decode_message/1)
        |> Enum.reject(&is_nil/1)
      {:error, _} -> []
    end
  end

  def clear(workspace, chat_id) do
    session_path(workspace, chat_id) |> File.rm()
  end

  def sanitize_for_persistence(messages, budget) when is_struct(budget, PiCore.TokenBudget) do
    max_chars = PiCore.TokenBudget.per_tool_result_cap(budget) * 4 * 2
    Enum.map(messages, fn msg ->
      if msg.role == "toolResult" and is_binary(msg.content) and byte_size(msg.content) > max_chars do
        %{msg | content: PiCore.Truncate.head_tail(msg.content, max_chars)}
      else
        msg
      end
    end)
  end
  def sanitize_for_persistence(messages, _), do: messages

  defp session_path(workspace, chat_id) do
    Path.join([workspace, "sessions", "#{chat_id}.jsonl"])
  end

  defp ensure_dir(path) do
    File.mkdir_p!(Path.dirname(path))
  end

  defp cap_messages(messages) when length(messages) > @max_messages do
    Enum.drop(messages, length(messages) - @max_messages)
  end
  defp cap_messages(messages), do: messages

  defp encode_message(msg) when is_map(msg) do
    Jason.encode!(msg)
  end

  defp decode_message(line) do
    case Jason.decode(line) do
      {:ok, data} -> data
      _ -> nil
    end
  end
end
```

- [ ] **Step 4: Run tests**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/session_store_test.exs`
Expected: all PASS

- [ ] **Step 5: Commit**

Message: `rewrite SessionStore for per-chat JSONL files with 500 cap`

---

### Task 2: Wire persistence into Session

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/session.ex`

- [ ] **Step 1: Load messages on init**

Read `v3/apps/pi_core/lib/pi_core/session.ex`. In `init/1`, after building the state struct but before `schedule_idle_timeout`, add:

```elixir
    # Load persisted session messages
    loaded_messages = if opts[:chat_id] do
      PiCore.SessionStore.load(opts.workspace, opts[:chat_id])
    else
      []
    end

    state = %{state | messages: loaded_messages}
```

- [ ] **Step 2: Append after completed turn**

In `handle_info({ref, {:ok, new_messages}}, state)`, after updating `state.messages`, add persistence calls.

For the main task branch (line ~158):
```elixir
    if state.active_task && state.active_task.ref == ref do
      state = %{state | messages: state.messages ++ new_messages, active_task: nil}
      # Persist new messages
      if state.chat_id, do: SessionStore.append_many(state.workspace, state.chat_id, new_messages)
      deliver_last_assistant(new_messages, ref, state)
      {:noreply, state}
```

For the parallel task branch (line ~165):
```elixir
        {%{user_msg: user_msg}, remaining} ->
          state = %{state | messages: state.messages ++ [user_msg | new_messages], parallel_tasks: remaining}
          # Persist new messages
          if state.chat_id, do: SessionStore.append_many(state.workspace, state.chat_id, [user_msg | new_messages])
          deliver_last_assistant(new_messages, ref, state)
          {:noreply, state}
```

- [ ] **Step 3: Save after compaction**

In `run_prompt/2`, after compaction runs, if it actually compacted, save the full compacted state:

```elixir
    {compacted_messages, did_compact} = Compaction.maybe_compact(messages, compaction_opts)

    # If compaction happened, persist the compacted state
    if did_compact and state.chat_id do
      SessionStore.save(state.workspace, state.chat_id, compacted_messages)
    end
```

- [ ] **Step 4: Update clear call**

In `handle_cast(:reset, state)`, update the clear call to pass chat_id:

```elixir
  def handle_cast(:reset, state) do
    if state.chat_id, do: PiCore.SessionStore.clear(state.workspace, state.chat_id)
    {:noreply, %{state | messages: [], active_task: nil, parallel_tasks: %{}}}
  end
```

- [ ] **Step 5: Run full test suite**

Run: `cd v3 && mix test apps/pi_core/test/ --exclude slow`
Expected: all PASS

- [ ] **Step 6: Commit**

Message: `wire session persistence: load on init, append on turn, save on compaction`

---

### Task 3: Full test run and cleanup

- [ ] **Step 1: Run full test suite**

Run: `cd v3 && mix test --exclude slow`

- [ ] **Step 2: Check for compiler warnings**

Run: `cd v3 && mix compile --warnings-as-errors 2>&1 | grep "warning:" | grep -v "apps/data\|Reminder\|catch.*rescue\|unused.*data\|never match\|Bcrypt\|telegram_pid\|clauses.*handle_info"`

- [ ] **Step 3: Commit if any fixes needed**

Message: `fix warnings from session persistence`
