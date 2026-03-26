# Tool Status, Typing Refresh & Group Persistence — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep users informed during tool execution (status messages + typing indicator), and fix group chat context loss by persisting all messages to disk.

**Architecture:** Three changes: (1) Route `:tool_call` events from PiCore.Loop through Instance.Sup to the Telegram agent, which edits the streaming message with a status string and refreshes typing every 4s. (2) Replace volatile ETS GroupBuffer with direct SessionStore persistence — every group message goes to disk immediately. (3) Add `push_message/2` to Session for recording messages without triggering LLM.

**Tech Stack:** Elixir/OTP, GenServer, PiCore.SessionStore (JSONL), Telegram Bot API (`sendChatAction`)

---

### Task 1: Create ToolStatus module

**Files:**
- Create: `v3/apps/druzhok/lib/druzhok/agent/tool_status.ex`

- [ ] **Step 1: Create the module**

```elixir
defmodule Druzhok.Agent.ToolStatus do
  @moduledoc "Maps tool names to Russian status strings for Telegram."

  @status_map %{
    "web_fetch" => "Ищу в интернете...",
    "bash" => "Выполняю команду...",
    "read" => "Читаю файл...",
    "write" => "Пишу файл...",
    "edit" => "Редактирую файл...",
    "grep" => "Ищу в файлах...",
    "find" => "Ищу в файлах...",
    "memory_search" => "Ищу в памяти...",
    "memory_write" => "Сохраняю в память...",
    "generate_image" => "Генерирую изображение...",
    "send_file" => "Отправляю файл...",
    "set_reminder" => "Устанавливаю напоминание...",
  }

  def status_text(tool_name) do
    Map.get(@status_map, String.downcase(tool_name), "Работаю...")
  end
end
```

- [ ] **Step 2: Verify compilation**

Run: `cd v3 && mix compile 2>&1 | grep error`
Expected: no errors

- [ ] **Step 3: Commit**

```
git add v3/apps/druzhok/lib/druzhok/agent/tool_status.ex
git commit -m "add ToolStatus module for tool name to status text mapping"
```

---

### Task 2: Route tool_call events to Telegram agent

The `on_event` callback in `Instance.Sup` currently only broadcasts to `Druzhok.Events`. It needs to also send `:tool_call` events to the Telegram agent process so it can show status + refresh typing.

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/instance/sup.ex` (lines 32-34)

- [ ] **Step 1: Update on_event to route tool_call events**

In `v3/apps/druzhok/lib/druzhok/instance/sup.ex`, replace the `on_event` closure (lines 32-34):

```elixir
    on_event = fn event ->
      Druzhok.Events.broadcast(name, event)
    end
```

with:

```elixir
    on_event = fn event ->
      Druzhok.Events.broadcast(name, event)
      if event[:type] == :tool_call do
        case Registry.lookup(Druzhok.Registry, {name, :telegram}) do
          [{pid, _}] -> send(pid, {:pi_tool_status, event[:name]})
          [] -> :ok
        end
      end
    end
```

This sends `{:pi_tool_status, "web_fetch"}` (for example) to the Telegram agent whenever a tool call starts.

- [ ] **Step 2: Verify compilation**

Run: `cd v3 && mix compile 2>&1 | grep error`
Expected: no errors

- [ ] **Step 3: Commit**

```
git add v3/apps/druzhok/lib/druzhok/instance/sup.ex
git commit -m "route tool_call events to Telegram agent for status display"
```

---

### Task 3: Handle tool status in Telegram agent (status message + typing refresh)

Add three things to the Telegram agent:
1. `typing_timer` field in state
2. Handler for `{:pi_tool_status, tool_name}` — edit/send status message + start typing timer
3. Handler for `:refresh_typing` — re-send chat action + schedule next
4. Cancel typing timer in existing `pi_delta` and `pi_response` handlers

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/agent/telegram.ex`

- [ ] **Step 1: Add `typing_timer` to struct**

In `v3/apps/druzhok/lib/druzhok/agent/telegram.ex`, add `typing_timer` to the struct (line 34, before `offset: 0`):

```elixir
    :typing_timer,
    offset: 0
```

- [ ] **Step 2: Add `handle_info` for `:pi_tool_status`**

Insert before the existing `handle_info(_msg, state)` catch-all (line 190):

```elixir
  # --- Tool status from PiCore (show status message + start typing refresh) ---

  def handle_info({:pi_tool_status, tool_name}, state) do
    state = cancel_typing_timer(state)
    status_text = Druzhok.Agent.ToolStatus.status_text(tool_name)

    # Edit existing streaming message or send a new one
    state = if state.chat_id do
      streamer = state.streamer
      case streamer.message_id do
        nil ->
          case API.send_message(state.token, state.chat_id, status_text) do
            {:ok, %{"message_id" => msg_id}} ->
              %{state | streamer: Streamer.mark_sent(streamer, System.monotonic_time(:millisecond), msg_id)}
            _ -> state
          end
        msg_id ->
          API.edit_message_text(state.token, state.chat_id, msg_id, status_text)
          state
      end
    else
      state
    end

    # Start typing refresh timer
    state = start_typing_timer(state)
    {:noreply, state}
  end

  def handle_info(:refresh_typing, state) do
    if state.chat_id do
      API.send_chat_action(state.token, state.chat_id)
    end
    state = start_typing_timer(state)
    {:noreply, state}
  end
```

- [ ] **Step 3: Add typing timer helpers**

Add these private functions at the end of the module, before the closing `end` (before line 735):

```elixir
  defp start_typing_timer(state) do
    timer = Process.send_after(self(), :refresh_typing, 4_000)
    %{state | typing_timer: timer}
  end

  defp cancel_typing_timer(%{typing_timer: nil} = state), do: state
  defp cancel_typing_timer(%{typing_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | typing_timer: nil}
  end
```

- [ ] **Step 4: Cancel typing timer when streaming starts or response arrives**

In the `handle_info({:pi_delta, chunk, chat_id}, state)` handler (line 142), add `state = cancel_typing_timer(state)` as the first line of the function body:

```elixir
  def handle_info({:pi_delta, chunk, chat_id}, state) when is_binary(chunk) do
    state = cancel_typing_timer(state)
    state = %{state | chat_id: chat_id}
    streamer = Streamer.append(state.streamer, chunk)
    state = handle_streaming_delta(%{state | streamer: streamer})
    {:noreply, state}
  end
```

In the `handle_info({:pi_delta, chunk}, state)` handler (line 151), add the same:

```elixir
  def handle_info({:pi_delta, chunk}, state) when is_binary(chunk) do
    state = cancel_typing_timer(state)
    streamer = Streamer.append(state.streamer, chunk)
    state = handle_streaming_delta(%{state | streamer: streamer})
    {:noreply, state}
  end
```

In both `handle_info({:pi_response, ...}, state)` handlers (lines 159 and 173), add `state = cancel_typing_timer(state)` as the first line:

```elixir
  def handle_info({:pi_response, %{text: text, chat_id: chat_id}}, state) when is_binary(text) and text != "" do
    state = cancel_typing_timer(state)
    state = %{state | chat_id: chat_id}
    # ... rest unchanged
  end

  def handle_info({:pi_response, %{text: text}}, state) when is_binary(text) and text != "" do
    state = cancel_typing_timer(state)
    # ... rest unchanged
  end
```

- [ ] **Step 5: Verify compilation**

Run: `cd v3 && mix compile 2>&1 | grep error`
Expected: no errors

- [ ] **Step 6: Commit**

```
git add v3/apps/druzhok/lib/druzhok/agent/telegram.ex
git commit -m "add tool status messages and typing indicator refresh"
```

---

### Task 4: Add push_message to PiCore.Session

Add a function that appends a user message to the session's message history and persists it to disk, without triggering an LLM call. Used for non-triggered group messages.

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/session.ex`

- [ ] **Step 1: Add public API function**

After the `prompt_heartbeat/2` function (line 36), add:

```elixir
  @doc "Append a user message to history without triggering LLM. For non-triggered group messages."
  def push_message(pid, text) do
    GenServer.cast(pid, {:push_message, text})
  end
```

- [ ] **Step 2: Add handle_cast**

After the `handle_cast({:prompt_heartbeat, text}, state)` handler (line 102), add:

```elixir
  def handle_cast({:push_message, text}, state) do
    state = schedule_idle_timeout(state)
    user_msg = %Loop.Message{role: "user", content: text, timestamp: System.os_time(:millisecond)}
    state = %{state | messages: state.messages ++ [user_msg]}
    if state.chat_id, do: SessionStore.append_many(state.workspace, state.chat_id, [user_msg])
    {:noreply, state}
  end
```

- [ ] **Step 3: Verify compilation**

Run: `cd v3 && mix compile 2>&1 | grep error`
Expected: no errors

- [ ] **Step 4: Commit**

```
git add v3/apps/pi_core/lib/pi_core/session.ex
git commit -m "add push_message for recording messages without LLM call"
```

---

### Task 5: Replace GroupBuffer with SessionStore persistence

Change `process_group_message_buffer` in the Telegram agent to persist non-triggered messages via Session/SessionStore instead of the ETS GroupBuffer.

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/agent/telegram.ex` (lines 427-461)

- [ ] **Step 1: Rewrite `process_group_message_buffer` for non-triggered messages**

Replace the entire `process_group_message_buffer` function (lines 427-461) with:

```elixir
  defp process_group_message_buffer(chat_id, text, sender_name, file, is_triggered, _buffer_size, chat, state) do
    if is_triggered do
      {resolved_text, saved_file} = resolve_voice_or_file(text, file, chat_id, state)
      {prompt, display} = build_group_prompt_with_intro("buffer", chat, resolved_text, sender_name, saved_file, true)

      emit(state, :user_message, %{text: display, sender: sender_name, chat_id: chat_id})
      API.send_chat_action(state.token, chat_id)
      dispatch_prompt(prompt, chat_id, true, state)
      state
    else
      # Persist to session without triggering LLM
      file_ref = if file, do: "[#{file.name || "file"}]", else: nil
      msg_text = build_group_prompt(text, sender_name, file_ref, false)
      persist_group_message(state.instance_name, chat_id, msg_text, state)

      emit(state, :user_message, %{text: "[#{sender_name}]: #{text}", sender: sender_name, chat_id: chat_id})
      state
    end
  end
```

- [ ] **Step 2: Add `persist_group_message` helper**

Add this private function after `dispatch_session` (after line 647):

```elixir
  defp persist_group_message(instance_name, chat_id, text, state) do
    # If session exists, push to it (persists to disk + in-memory)
    case Registry.lookup(Druzhok.Registry, {instance_name, :session, chat_id}) do
      [{pid, _}] ->
        PiCore.Session.push_message(pid, text)
      [] ->
        # No session running — write directly to disk so it's loaded on next session start
        workspace = case :persistent_term.get({:druzhok_session_config, instance_name}, nil) do
          %{workspace: ws} -> ws
          _ -> state.workspace
        end
        if workspace do
          msg = %PiCore.Loop.Message{role: "user", content: text, timestamp: System.os_time(:millisecond)}
          PiCore.SessionStore.append_many(workspace, chat_id, [msg])
        end
    end
  end
```

- [ ] **Step 3: Remove GroupBuffer references from group commands**

In the `process_group_message` function (line 383), remove the `GroupBuffer.clear` call from the `/reset` command handler. Replace:

```elixir
      {:command, "reset"} when is_owner ->
        dispatch_session(chat_id, state, &PiCore.Session.reset/1)
        Druzhok.GroupBuffer.clear(state.instance_name, chat_id)
        API.send_message(state.token, chat_id, "Session reset!")
        state
```

with:

```elixir
      {:command, "reset"} when is_owner ->
        dispatch_session(chat_id, state, &PiCore.Session.reset/1)
        API.send_message(state.token, chat_id, "Session reset!")
        state
```

In the `handle_mode_command` function (line 467), remove the `GroupBuffer.clear` call. Replace:

```elixir
        if mode == "buffer", do: Druzhok.GroupBuffer.clear(state.instance_name, chat_id)
```

with nothing (just delete the line).

- [ ] **Step 4: Verify compilation**

Run: `cd v3 && mix compile 2>&1 | grep error`
Expected: no errors

- [ ] **Step 5: Commit**

```
git add v3/apps/druzhok/lib/druzhok/agent/telegram.ex
git commit -m "replace GroupBuffer with SessionStore for group message persistence"
```

---

### Task 6: Remove GroupBuffer and ETS table

**Files:**
- Delete: `v3/apps/druzhok/lib/druzhok/group_buffer.ex`
- Modify: `v3/apps/druzhok/lib/druzhok/application.ex` (line 8)

- [ ] **Step 1: Remove ETS table creation from Application**

In `v3/apps/druzhok/lib/druzhok/application.ex`, remove line 8:

```elixir
    :ets.new(:druzhok_group_buffer, [:set, :public, :named_table])
```

- [ ] **Step 2: Delete GroupBuffer module**

```bash
rm v3/apps/druzhok/lib/druzhok/group_buffer.ex
```

- [ ] **Step 3: Remove any remaining GroupBuffer references**

Search for remaining references:

```bash
cd v3 && grep -r "GroupBuffer\|group_buffer" --include="*.ex" --include="*.exs" -l
```

If any files still reference it, remove those references. The main ones should already be gone from Task 5. Check for test files or other modules.

- [ ] **Step 4: Verify compilation**

Run: `cd v3 && mix compile 2>&1 | grep error`
Expected: no errors (warnings about unused variables are OK)

- [ ] **Step 5: Commit**

```
git add -A
git commit -m "remove GroupBuffer module and ETS table"
```

---

### Task 7: Add tool narration to system prompt

Add instructions to the workspace template telling the bot to explain what it's doing during tool calls and explain errors.

**Files:**
- Modify: `workspace-template/AGENTS.md`

- [ ] **Step 1: Update the "Работа с инструментами" section**

In `workspace-template/AGENTS.md`, add a new subsection after the existing "## Работа с инструментами" header (after line 63), before "### Не зацикливайся":

```markdown
### Комментируй свои действия

Перед использованием инструментов кратко объясни что собираешься делать и зачем:
- "Сейчас поищу на сайте..." перед web_fetch
- "Проверю файл..." перед read
- "Напишу скрипт..." перед bash

Если инструмент вернул ошибку — объясни пользователю что произошло и что будешь делать дальше. Не молчи и не повторяй бесконечно.
```

- [ ] **Step 2: Commit**

```
git add workspace-template/AGENTS.md
git commit -m "add tool narration instructions to AGENTS.md template"
```

---

### Task 8: WebSocket tool status events

Route tool status events to the WebSocket chat channel for web dashboard support.

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/instance/sup.ex` (on_event closure)
- Modify: `v3/apps/druzhok_web/lib/druzhok_web_web/channels/chat_channel.ex`

- [ ] **Step 1: Route tool_call events to WebSocket channel too**

The `on_event` closure in `v3/apps/druzhok/lib/druzhok/instance/sup.ex` (from Task 2) already routes to Telegram. Extend it to also route to any WebSocket channel caller. Update the closure to:

```elixir
    on_event = fn event ->
      Druzhok.Events.broadcast(name, event)
      if event[:type] == :tool_call do
        # Route to Telegram agent
        case Registry.lookup(Druzhok.Registry, {name, :telegram}) do
          [{pid, _}] -> send(pid, {:pi_tool_status, event[:name]})
          [] -> :ok
        end
        # Route to all sessions (they'll forward to their callers including WebSocket)
        Registry.select(Druzhok.Registry, [
          {{{name, :session, :_}, :"$1", :_}, [], [:"$1"]}
        ])
        |> Enum.each(fn pid ->
          send(pid, {:pi_tool_status, event[:name]})
        end)
      end
    end
```

Actually, a simpler approach: handle `:pi_tool_status` in the ChatChannel directly. The Session already has a `caller` which is the ChatChannel process for WebSocket connections.

Instead, update the Session to forward tool status to its caller. Add to `v3/apps/pi_core/lib/pi_core/session.ex`, a handler:

```elixir
  def handle_info({:pi_tool_status, tool_name}, state) do
    pid = response_target(state)
    if pid, do: send(pid, {:pi_tool_status, tool_name, state.chat_id})
    {:noreply, state}
  end
```

Wait — that won't work because `on_event` fires in the Loop Task, not in the Session process. The `on_event` callback runs inside the Task spawned by Session. Let me reconsider.

The simplest approach: in Instance.Sup's `on_event`, also broadcast a PubSub event that the ChatChannel subscribes to. But that's overengineered.

Simpler: the `on_event` closure already runs in the context of a Task spawned by Session. We don't have direct access to the WebSocket channel pid. The cleanest approach for now: handle it in the ChatChannel by subscribing to Druzhok.Events (which already broadcasts all events).

- [ ] **Step 1 (revised): Add tool_status handler to ChatChannel**

In `v3/apps/druzhok_web/lib/druzhok_web_web/channels/chat_channel.ex`, add a handler for the `:pi_tool_status` message. But since the channel may not receive this directly, instead handle it via the Events broadcast that already happens.

Actually, the ChatChannel doesn't subscribe to Druzhok.Events. The simpler path: have Instance.Sup's on_event also look up WebSocket channel sessions and send to them. But session callers are dynamic.

The simplest working approach: extend the on_event in Instance.Sup to send tool status via the same `on_delta` path — just use a different message format. Add to Instance.Sup's `on_event`:

This is getting complex. Let's keep it simple for now — the WebSocket channel handler just needs to handle the message if it arrives. We'll pipe it through the same path as `:pi_delta`.

Replace the `on_event` closure in `v3/apps/druzhok/lib/druzhok/instance/sup.ex` with:

```elixir
    on_event = fn event ->
      Druzhok.Events.broadcast(name, event)
      if event[:type] == :tool_call do
        tool_name = event[:name]
        # Send to Telegram agent
        case Registry.lookup(Druzhok.Registry, {name, :telegram}) do
          [{pid, _}] -> send(pid, {:pi_tool_status, tool_name})
          [] -> :ok
        end
        # Send to all active WebSocket channel callers via sessions
        # (Sessions forward unknown messages; channels will handle pi_tool_status)
      end
    end
```

For WebSocket support, add the handler in the ChatChannel:

```elixir
  def handle_info({:pi_tool_status, tool_name, chat_id}, socket) do
    status = Druzhok.Agent.ToolStatus.status_text(tool_name)
    push(socket, "tool_status", %{tool: tool_name, status: status, chat_id: chat_id})
    {:noreply, socket}
  end
```

And in Session, add forwarding so the WebSocket caller gets the event:

```elixir
  def handle_info({:pi_tool_status, tool_name}, state) do
    pid = response_target(state)
    if pid && pid != self() do
      send(pid, {:pi_tool_status, tool_name, state.chat_id})
    end
    {:noreply, state}
  end
```

- [ ] **Step 2: Verify compilation**

Run: `cd v3 && mix compile 2>&1 | grep error`
Expected: no errors

- [ ] **Step 3: Commit**

```
git add v3/apps/druzhok/lib/druzhok/instance/sup.ex v3/apps/pi_core/lib/pi_core/session.ex v3/apps/druzhok_web/lib/druzhok_web_web/channels/chat_channel.ex
git commit -m "add WebSocket tool status events for web dashboard"
```

---

### Task 9: Manual integration test

- [ ] **Step 1: Compile and start the server**

```bash
cd v3 && mix compile && mix phx.server
```

- [ ] **Step 2: Test typing + tool status**

Send a message to the bot that triggers a tool call (e.g., ask it to fetch a website). Verify:
- Status message appears in chat (e.g., "Ищу в интернете...")
- Typing indicator stays alive for the full duration of tool execution
- Status message is replaced by the actual response when done

- [ ] **Step 3: Test group persistence**

In a group chat with "buffer" mode:
1. Send several non-triggered messages
2. Restart the app (`mix phx.server`)
3. Send a triggered message (@mention)
4. Verify the bot has context from the messages sent before the restart

- [ ] **Step 4: Test error handling**

Ask the bot to fetch an unreachable URL. Verify it explains the error instead of going silent.

- [ ] **Step 5: Commit all remaining changes**

```
git add -A
git commit -m "integration test cleanup"
```
