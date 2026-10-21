# Memory Flush + Dreaming — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a daily "dreaming" session where the bot reflects on conversations and evolves its character files (USER.md, SOUL.md, MEMORY.md).

**Architecture:** Note: Memory flush before compaction already exists (`PiCore.Memory.Flush`). This plan adds: (1) `DreamDigest` module to extract clean conversation history from session JSONL files, (2) `DREAM.md` workspace template with reflection instructions, (3) hourly dream check in Scheduler that starts a temporary session with the dream prompt, (4) `dream_hour` field on instances for configuration.

**Tech Stack:** Elixir/OTP, Ecto, Phoenix LiveView, PiCore.SessionStore (JSONL)

---

### Task 1: Add dream_hour to instances + SOUL.md template

**Files:**
- Create: `v3/apps/druzhok/priv/repo/migrations/20260326000005_add_dream_hour_to_instances.exs`
- Modify: `v3/apps/druzhok/lib/druzhok/instance.ex`
- Modify: `workspace-template/SOUL.md`
- Create: `workspace-template/DREAM.md`

- [ ] **Step 1: Create migration**

Create `v3/apps/druzhok/priv/repo/migrations/20260326000005_add_dream_hour_to_instances.exs`:

```elixir
defmodule Druzhok.Repo.Migrations.AddDreamHourToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :dream_hour, :integer, default: -1
    end
  end
end
```

- [ ] **Step 2: Add field to Instance schema + changeset**

In `v3/apps/druzhok/lib/druzhok/instance.ex`, add after `daily_token_limit`:

```elixir
    field :dream_hour, :integer, default: -1
```

Add `:dream_hour` to the cast list in changeset.

- [ ] **Step 3: Add "Мои наблюдения" section to SOUL.md template**

Append to `workspace-template/SOUL.md`:

```markdown

## Мои наблюдения

_Этот раздел обновляется автоматически. Здесь я записываю что замечаю о себе._
```

- [ ] **Step 4: Create DREAM.md template**

Create `workspace-template/DREAM.md`:

```markdown
# Инструкции для сна

Ты просыпаешься между сессиями. Время для рефлексии.

Ниже — выжимка из сегодняшних разговоров:

{CONVERSATIONS}

## Задачи

1. Прочитай `USER.md`. Обнови его:
   - Добавь новую информацию о пользователях из разговоров выше
   - Если какой-то факт уже есть — не дублируй
   - Если информация противоречит старой — обнови (например, "переехал", "сменил работу")
   - НЕ удаляй факты только потому что они не упоминались сегодня — у тебя неполный контекст
   - Если USER.md стал длиннее ~50 строк — объедини похожие факты, убери очевидные повторы
   - Пиши компактно: факты, не пересказ разговоров

2. Прочитай `SOUL.md`. Обнови ТОЛЬКО раздел "## Мои наблюдения" в конце — что ты заметил о себе, своём стиле, что работает а что нет. Не трогай остальные разделы.

3. Прочитай `MEMORY.md`. Перенеси важные долгосрочные факты из разговоров если есть. Не дублируй, объединяй похожее.

Используй read, edit, memory_search. Ответь [NO_REPLY] когда закончишь.
```

- [ ] **Step 5: Verify compilation and run migration**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix compile && mix ecto.migrate`

- [ ] **Step 6: Commit**

```
git add v3/apps/druzhok/priv/repo/migrations/20260326000005_add_dream_hour_to_instances.exs v3/apps/druzhok/lib/druzhok/instance.ex workspace-template/SOUL.md workspace-template/DREAM.md
git commit -m "add dream_hour to instances, DREAM.md and SOUL.md templates"
```

---

### Task 2: Create DreamDigest module

Reads session JSONL files and produces a clean conversation digest for the dreaming prompt.

**Files:**
- Create: `v3/apps/druzhok/lib/druzhok/dream_digest.ex`

- [ ] **Step 1: Create the module**

Create `v3/apps/druzhok/lib/druzhok/dream_digest.ex`:

```elixir
defmodule Druzhok.DreamDigest do
  @moduledoc "Builds a conversation digest from session JSONL files for the dreaming prompt."

  @max_messages_per_session 30
  @max_content_chars 500
  @max_total_chars 16_000

  def build(workspace) do
    sessions_dir = Path.join(workspace, "sessions")

    case File.ls(sessions_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(fn file -> {file, Path.join(sessions_dir, file)} end)
        |> Enum.map(fn {name, path} -> {name, parse_session(path)} end)
        |> Enum.reject(fn {_, msgs} -> msgs == [] end)
        |> format_digest()

      {:error, _} -> ""
    end
  end

  defp parse_session(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&decode_line/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(fn msg -> msg["role"] in ["user", "assistant"] end)
        |> Enum.reject(fn msg ->
          content = msg["content"] || ""
          String.starts_with?(content, "HEARTBEAT") or
            String.starts_with?(content, "[System:")
        end)
        |> Enum.take(-@max_messages_per_session)

      {:error, _} -> []
    end
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{"role" => _} = msg} -> msg
      _ -> nil
    end
  end

  defp format_digest(sessions) do
    {result, _total} = Enum.reduce(sessions, {"", 0}, fn {name, msgs}, {acc, total} ->
      if total >= @max_total_chars do
        {acc, total}
      else
        chat_id = name |> String.replace(".jsonl", "")
        section = "--- Chat #{chat_id} ---\n" <>
          Enum.map_join(msgs, "\n", fn msg ->
            content = msg["content"] || ""
            truncated = String.slice(content, 0, @max_content_chars)
            "[#{msg["role"]}] #{truncated}"
          end) <> "\n\n"

        new_total = total + byte_size(section)
        if new_total > @max_total_chars do
          {acc, total}
        else
          {acc <> section, new_total}
        end
      end
    end)
    result
  end
end
```

- [ ] **Step 2: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix compile`

- [ ] **Step 3: Commit**

```
git add v3/apps/druzhok/lib/druzhok/dream_digest.ex
git commit -m "add DreamDigest module for conversation extraction"
```

---

### Task 3: Add dream tick to Scheduler

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/scheduler.ex`

- [ ] **Step 1: Add dream_hour to struct and init**

In the struct (line 13), add `:dream_hour` and `:dream_timer`:

```elixir
  defstruct [
    :instance_name,
    :workspace,
    :heartbeat_interval,
    :heartbeat_timer,
    :reminder_timer,
    :dream_timer,
    :dream_hour
  ]
```

In `init/1` (line 33), add dream_hour from opts and schedule the check:

```elixir
    state = %__MODULE__{
      instance_name: opts.instance_name,
      workspace: opts.workspace,
      heartbeat_interval: opts[:heartbeat_interval] || 0,
      dream_hour: opts[:dream_hour] || -1,
    }

    state = schedule_heartbeat(state)
    state = schedule_reminder_check(state)
    state = schedule_dream_check(state)
```

- [ ] **Step 2: Add dream tick handler**

Add after the reminder handler (after line 102):

```elixir
  # --- Dreaming ---

  def handle_info(:dream_check, state) do
    if should_dream?(state) do
      Logger.info("[#{state.instance_name}] Starting dream session")
      Druzhok.Events.broadcast(state.instance_name, %{type: :dream, text: "Dream session started"})
      run_dream(state)
    end

    state = schedule_dream_check(state)
    {:noreply, state}
  end
```

- [ ] **Step 3: Add dream helper functions**

Add to the private section:

```elixir
  defp should_dream?(%{dream_hour: -1}), do: false
  defp should_dream?(state) do
    current_hour = case DateTime.now(instance_timezone(state)) do
      {:ok, dt} -> dt.hour
      _ -> DateTime.utc_now().hour
    end
    current_hour == state.dream_hour
  end

  defp instance_timezone(state) do
    case Druzhok.Repo.get_by(Druzhok.Instance, name: state.instance_name) do
      %{timezone: tz} when tz != nil and tz != "" -> tz
      _ -> "UTC"
    end
  end

  defp run_dream(state) do
    dream_md = Path.join(state.workspace, "DREAM.md")

    case File.read(dream_md) do
      {:ok, template} ->
        template = String.trim(template)
        if template != "" do
          digest = Druzhok.DreamDigest.build(state.workspace)
          prompt = String.replace(template, "{CONVERSATIONS}", digest)

          # Start a temporary dream session (no chat_id, no Telegram)
          config = :persistent_term.get({:druzhok_session_config, state.instance_name}, nil)
          if config do
            Task.start(fn ->
              case PiCore.Session.start_link(%{
                workspace: config.workspace,
                model: config.model,
                provider: config[:provider],
                api_url: config.api_url,
                api_key: config.api_key,
                instance_name: state.instance_name,
                on_delta: nil,
                on_event: nil,
                tools: dream_tools(),
                extra_tool_context: %{workspace: config.workspace, instance_name: state.instance_name},
                timezone: config[:timezone] || "UTC"
              }) do
                {:ok, pid} ->
                  PiCore.Session.prompt(pid, prompt)
                  # Give the dream session time to complete (max 2 minutes)
                  Process.sleep(120_000)
                  Process.exit(pid, :normal)
                {:error, reason} ->
                  Logger.warning("[#{state.instance_name}] Dream session failed to start: #{inspect(reason)}")
              end
            end)
          end
        end

      {:error, _} -> :ok
    end
  end

  defp dream_tools do
    [
      PiCore.Tools.Read.new(),
      PiCore.Tools.Write.new(),
      PiCore.Tools.Edit.new(),
      PiCore.Tools.Find.new(),
      PiCore.Tools.Grep.new(),
      PiCore.Tools.MemorySearch.new(),
      PiCore.Tools.MemoryWrite.new(),
    ]
  end

  defp schedule_dream_check(%{dream_hour: -1} = state), do: state
  defp schedule_dream_check(state) do
    # Check every hour
    timer = Process.send_after(self(), :dream_check, 3_600_000)
    %{state | dream_timer: timer}
  end
```

- [ ] **Step 4: Pass dream_hour from Instance.Sup**

In `v3/apps/druzhok/lib/druzhok/instance/sup.ex`, find where Scheduler is started in the children list. Add `dream_hour` to the opts. Change:

```elixir
      {Druzhok.Scheduler, %{
        instance_name: name,
        workspace: config.workspace,
        heartbeat_interval: config.heartbeat_interval,
        registry_name: {:via, Registry, {Druzhok.Registry, {name, :scheduler}}},
      }},
```

to:

```elixir
      {Druzhok.Scheduler, %{
        instance_name: name,
        workspace: config.workspace,
        heartbeat_interval: config.heartbeat_interval,
        dream_hour: config[:dream_hour] || -1,
        registry_name: {:via, Registry, {Druzhok.Registry, {name, :scheduler}}},
      }},
```

Also pass `dream_hour` from the instance record in `InstanceManager.create`. Check `v3/apps/druzhok/lib/druzhok/instance_manager.ex` — find where the config map is built for `Instance.Sup` and add `dream_hour: inst.dream_hour || -1` (or from opts).

- [ ] **Step 5: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix compile`

- [ ] **Step 6: Commit**

```
git add v3/apps/druzhok/lib/druzhok/scheduler.ex v3/apps/druzhok/lib/druzhok/instance/sup.ex v3/apps/druzhok/lib/druzhok/instance_manager.ex
git commit -m "add dream session to scheduler with hourly check"
```

---

### Task 4: Add dream hour to dashboard

**Files:**
- Modify: `v3/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex`

- [ ] **Step 1: Add event handler**

Add after the `change_token_limit` handler:

```elixir
  def handle_event("change_dream_hour", %{"name" => name, "hour" => hour}, socket) do
    hour = case Integer.parse(hour) do
      {n, _} -> n
      :error -> -1
    end
    update_instance_field(name, %{dream_hour: hour})
    {:noreply, assign(socket, instances: list_instances())}
  end
```

- [ ] **Step 2: Add dropdown to instance header**

After the token limit form in the template, add:

```html
            <form phx-change="change_dream_hour" class="flex items-center gap-1">
              <input type="hidden" name="name" value={@selected} />
              <span class="text-[10px] text-gray-400">Dream</span>
              <select name="hour" class="border border-gray-300 rounded-lg px-2 py-1 text-xs focus:outline-none focus:ring-1 focus:ring-gray-900">
                <option value="-1" selected={selected_field(@instances, @selected, :dream_hour) == -1 or is_nil(selected_field(@instances, @selected, :dream_hour))}>Off</option>
                <%= for h <- 0..23 do %>
                  <option value={h} selected={selected_field(@instances, @selected, :dream_hour) == h}><%= String.pad_leading("#{h}", 2, "0") %>:00</option>
                <% end %>
              </select>
            </form>
```

- [ ] **Step 3: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix compile`

- [ ] **Step 4: Commit**

```
git add v3/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex
git commit -m "add dream hour dropdown to dashboard"
```
