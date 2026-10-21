# Heartbeat Pruning + Tool Result Truncation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate token waste by pruning HEARTBEAT_OK exchanges from session history and truncating old tool results before sending to LLM.

**Architecture:** Two changes in PiCore: (1) In Session, when a heartbeat task returns HEARTBEAT_OK, roll back the user message and discard all new messages instead of appending them. (2) In Transform, truncate toolResult content in older messages to 200 chars before the LLM call.

**Tech Stack:** Elixir/OTP, PiCore.Session, PiCore.Transform

---

### Task 1: Prune heartbeat exchanges from session history

When a heartbeat task completes with HEARTBEAT_OK, the entire exchange (user prompt + tool calls + tool results + assistant response) should be discarded — not appended to messages, not written to disk.

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/session.ex`

- [ ] **Step 1: Track pre-heartbeat message count**

In `do_prompt/3` (around line 254), when running a heartbeat as the main task (not parallel), record the message count before appending the user message. Store it in a new map `heartbeat_msg_counts` keyed by task ref.

Add `heartbeat_msg_counts: %{}` to the struct (line 19, alongside `heartbeat_refs`):

```elixir
    heartbeat_refs: MapSet.new(),
    heartbeat_msg_counts: %{}
```

In `do_prompt/3`, in the `else` branch (main task, line 267-271), when heartbeat is true, record the count:

```elixir
    else
      state = %{state | messages: state.messages ++ [user_msg]}
      task = Task.async(fn -> run_prompt(state.messages, run_state) end)
      heartbeat_refs = if heartbeat, do: MapSet.put(state.heartbeat_refs, task.ref), else: state.heartbeat_refs
      heartbeat_msg_counts = if heartbeat,
        do: Map.put(state.heartbeat_msg_counts, task.ref, length(state.messages) - 1),
        else: state.heartbeat_msg_counts
      {:noreply, %{state | active_task: task, heartbeat_refs: heartbeat_refs, heartbeat_msg_counts: heartbeat_msg_counts}}
    end
```

The count is `length(state.messages) - 1` because we just appended the user message and want to know where to roll back to.

- [ ] **Step 2: Prune on heartbeat completion**

In `handle_info({ref, {:ok, new_messages}}, state)` (line 178), replace the main task branch (lines 184-189):

```elixir
    if state.active_task && state.active_task.ref == ref do
      if is_heartbeat && heartbeat_should_prune?(new_messages) do
        # HEARTBEAT_OK — discard entire exchange (user msg + tool calls + response)
        pre_count = Map.get(state.heartbeat_msg_counts, ref)
        rolled_back = if pre_count, do: Enum.take(state.messages, pre_count), else: state.messages
        state = %{state | messages: rolled_back, active_task: nil, heartbeat_msg_counts: Map.delete(state.heartbeat_msg_counts, ref)}
        if pre_count && state.chat_id do
          SessionStore.save(state.workspace, state.chat_id, rolled_back)
        end
        {:noreply, state}
      else
        # Normal completion — append and persist
        state = %{state | messages: state.messages ++ new_messages, active_task: nil, heartbeat_msg_counts: Map.delete(state.heartbeat_msg_counts, ref)}
        if state.chat_id, do: SessionStore.append_many(state.workspace, state.chat_id, new_messages)
        deliver_last_assistant(new_messages, ref, state, heartbeat: is_heartbeat)
        {:noreply, state}
      end
    else
```

- [ ] **Step 3: Add the heartbeat_should_prune? helper**

Add after `strip_heartbeat_ok` (after line 311):

```elixir
  defp heartbeat_should_prune?(new_messages) do
    case Enum.find(Enum.reverse(new_messages), &(&1.role == "assistant")) do
      nil -> true
      msg -> strip_heartbeat_ok(msg.content) == nil
    end
  end
```

- [ ] **Step 4: Clean up heartbeat_msg_counts in error/crash/abort/reset handlers**

In `handle_info({ref, {:error, reason}}, state)` (line 206), add cleanup:

```elixir
    state = %{state | heartbeat_refs: MapSet.delete(state.heartbeat_refs, ref),
                      heartbeat_msg_counts: Map.delete(state.heartbeat_msg_counts, ref)}
```

In `handle_info({:DOWN, ref, ...}, state)` (line 222), same:

```elixir
    state = %{state | heartbeat_refs: MapSet.delete(state.heartbeat_refs, ref),
                      heartbeat_msg_counts: Map.delete(state.heartbeat_msg_counts, ref)}
```

In `handle_cast(:abort, state)` (line 159), add:

```elixir
      {:noreply, %{state | active_task: nil,
                           heartbeat_refs: MapSet.delete(state.heartbeat_refs, ref),
                           heartbeat_msg_counts: Map.delete(state.heartbeat_msg_counts, ref)}}
```

In `handle_cast(:reset, state)` (line 169), add `heartbeat_msg_counts: %{}`:

```elixir
    {:noreply, %{state | messages: [], active_task: nil, parallel_tasks: %{}, heartbeat_refs: MapSet.new(), heartbeat_msg_counts: %{}}}
```

- [ ] **Step 5: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix compile`
Expected: compiles with no errors

- [ ] **Step 6: Commit**

```
git add v3/apps/pi_core/lib/pi_core/session.ex
git commit -m "prune HEARTBEAT_OK exchanges from session history"
```

---

### Task 2: Truncate old tool results in Transform

When building the LLM payload, truncate toolResult content in messages older than the last 4 messages. This prevents massive tool outputs (RSS feeds, failed Google searches) from consuming tokens on every subsequent call.

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/transform.ex`

- [ ] **Step 1: Add truncate_old_tool_results function**

Add after `compact_tool_results` (after line 59), before `safe_content`:

```elixir
  @tool_result_keep_recent 4
  @tool_result_max_old_chars 200

  @doc "Truncate toolResult content in older messages to save tokens."
  def truncate_old_tool_results(messages) do
    len = length(messages)
    cutoff = max(len - @tool_result_keep_recent, 0)

    Enum.with_index(messages, fn msg, idx ->
      if msg.role == "toolResult" && idx < cutoff do
        content = safe_content(msg.content) || ""
        if byte_size(content) > @tool_result_max_old_chars do
          truncated = String.slice(content, 0, @tool_result_max_old_chars) <>
            "\n... [truncated, was #{byte_size(content)} bytes]"
          %{msg | content: truncated}
        else
          msg
        end
      else
        msg
      end
    end)
  end
```

- [ ] **Step 2: Wire into transform_messages pipeline**

Replace `transform_messages` (line 65-69):

```elixir
  def transform_messages(messages, %TokenBudget{} = budget, current_iteration_start) do
    messages
    |> truncate_old_tool_results()
    |> strip_reasoning()
    |> compact_tool_results(budget, current_iteration_start)
  end
```

The order matters: truncate first (cheap, reduces input to subsequent steps), then strip reasoning, then compact if still over budget.

- [ ] **Step 3: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix compile`
Expected: compiles with no errors

- [ ] **Step 4: Commit**

```
git add v3/apps/pi_core/lib/pi_core/transform.ex
git commit -m "truncate old tool results before sending to LLM"
```
