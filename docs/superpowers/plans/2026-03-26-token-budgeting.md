# Token Budgeting + Runtime Injection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set daily token limits per bot instance with soft warnings, and inject runtime context (model, date, budget, sandbox) into the system prompt.

**Architecture:** Add `daily_token_limit` to instances table. New `Druzhok.TokenBudget` module queries today's usage and formats a runtime section. Session's `build_system_prompt` calls a `runtime_info_fn` callback (passed via extra_tool_context) to avoid circular dependency between PiCore and Druzhok. Dashboard gets a token limit input field.

**Tech Stack:** Elixir/OTP, Ecto, Phoenix LiveView

---

### Task 1: Add daily_token_limit to instances

**Files:**
- Create: `v3/apps/druzhok/priv/repo/migrations/20260326000004_add_daily_token_limit_to_instances.exs`
- Modify: `v3/apps/druzhok/lib/druzhok/instance.ex`

- [ ] **Step 1: Create migration**

Create file `v3/apps/druzhok/priv/repo/migrations/20260326000004_add_daily_token_limit_to_instances.exs`:

```elixir
defmodule Druzhok.Repo.Migrations.AddDailyTokenLimitToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :daily_token_limit, :integer, default: 0
    end
  end
end
```

- [ ] **Step 2: Add field to Instance schema and changeset**

In `v3/apps/druzhok/lib/druzhok/instance.ex`, add to schema (after `field :api_key, :string`):

```elixir
    field :daily_token_limit, :integer, default: 0
```

In the changeset `cast` list, add `:daily_token_limit`:

```elixir
    |> cast(attrs, [:name, :telegram_token, :model, :workspace, :active, :heartbeat_interval, :owner_telegram_id, :sandbox, :timezone, :api_key, :daily_token_limit])
```

- [ ] **Step 3: Verify compilation and run migration**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix compile && mix ecto.migrate`

- [ ] **Step 4: Commit**

```
git add v3/apps/druzhok/priv/repo/migrations/20260326000004_add_daily_token_limit_to_instances.exs v3/apps/druzhok/lib/druzhok/instance.ex
git commit -m "add daily_token_limit to instances table"
```

---

### Task 2: Add tokens_today query to LlmRequest

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/llm_request.ex`

- [ ] **Step 1: Add tokens_today function**

Add to `v3/apps/druzhok/lib/druzhok/llm_request.ex`, after the `summary_for_instance` function:

```elixir
  def tokens_today(instance_name) do
    today = Date.utc_today()
    start_of_day = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")

    result = from(r in __MODULE__,
      where: r.inserted_at >= ^start_of_day and r.instance_name == ^instance_name,
      select: %{
        input: sum(r.input_tokens),
        output: sum(r.output_tokens)
      }
    )
    |> Druzhok.Repo.one()

    {result.input || 0, result.output || 0}
  end
```

- [ ] **Step 2: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix compile`

- [ ] **Step 3: Commit**

```
git add v3/apps/druzhok/lib/druzhok/llm_request.ex
git commit -m "add tokens_today query for daily budget tracking"
```

---

### Task 3: Create TokenBudget module

**Files:**
- Create: `v3/apps/druzhok/lib/druzhok/token_budget.ex`

- [ ] **Step 1: Create the module**

Create file `v3/apps/druzhok/lib/druzhok/token_budget.ex`:

```elixir
defmodule Druzhok.TokenBudget do
  @moduledoc "Generates runtime context section for system prompt with token budget info."

  def runtime_section(instance_name, model, sandbox_type) do
    {input, output} = Druzhok.LlmRequest.tokens_today(instance_name)
    total_used = input + output

    limit = case Druzhok.Repo.get_by(Druzhok.Instance, name: instance_name) do
      %{daily_token_limit: l} when is_integer(l) and l > 0 -> l
      _ -> 0
    end

    now = DateTime.utc_now() |> Calendar.strftime("%Y-%m-%d %H:%M UTC")
    sandbox_label = sandbox_label(sandbox_type)
    tokens_line = tokens_line(total_used, limit)
    warning = budget_warning(total_used, limit)

    section = """
    ## Runtime

    - Модель: #{model}
    - Дата: #{now}
    - #{tokens_line}
    - Sandbox: #{sandbox_label}
    """

    if warning != "", do: section <> "\n" <> warning, else: section
  end

  defp tokens_line(used, 0) do
    "Токены сегодня: #{format_tokens(used)} (без лимита)"
  end
  defp tokens_line(used, limit) do
    remaining_pct = max(0, round((1 - used / limit) * 100))
    "Токены сегодня: #{format_tokens(used)} из #{format_tokens(limit)} (#{remaining_pct}% осталось)"
  end

  defp budget_warning(_used, 0), do: ""
  defp budget_warning(used, limit) do
    pct = used / limit * 100
    cond do
      pct > 100 -> "🛑 Лимит токенов исчерпан. Отвечай только на важные вопросы. Будь максимально кратким. Избегай tool calls."
      pct > 80 -> "⚠️ Экономь токены — отвечай кратко, минимум инструментов."
      true -> ""
    end
  end

  defp sandbox_label("docker"), do: "Docker (python3, node, bash)"
  defp sandbox_label("firecracker"), do: "Firecracker (isolated VM)"
  defp sandbox_label(_), do: "Local (без песочницы)"

  defp format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_tokens(n), do: "#{n}"
end
```

- [ ] **Step 2: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix compile`

- [ ] **Step 3: Commit**

```
git add v3/apps/druzhok/lib/druzhok/token_budget.ex
git commit -m "add TokenBudget module for runtime section generation"
```

---

### Task 4: Inject runtime section into system prompt

PiCore.Session can't call Druzhok modules directly (circular dependency). Pass a `runtime_info_fn` callback through `extra_tool_context`, same pattern as `model_info_fn`.

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/instance/sup.ex`
- Modify: `v3/apps/pi_core/lib/pi_core/session.ex`

- [ ] **Step 1: Pass runtime_info_fn from Instance.Sup**

In `v3/apps/druzhok/lib/druzhok/instance/sup.ex`, in the `extra_tool_context` map (inside `:persistent_term.put`, around line 109), add:

```elixir
        runtime_info_fn: fn ->
          Druzhok.TokenBudget.runtime_section(name, config.model, config[:sandbox] || "local")
        end,
```

Add it after the `image_generation_enabled` line.

- [ ] **Step 2: Call runtime_info_fn in build_system_prompt**

In `v3/apps/pi_core/lib/pi_core/session.ex`, modify `build_system_prompt` (line 474) to accept extra_tool_context and call the runtime function. Replace:

```elixir
  defp build_system_prompt(loader, workspace, group, budget, model) do
```

with:

```elixir
  defp build_system_prompt(loader, workspace, group, budget, model, extra_tool_context \\ %{}) do
```

Replace the last line of the function (line 491):

```elixir
    append_model_info(prompt, model)
```

with:

```elixir
    prompt = append_model_info(prompt, model)
    runtime_fn = extra_tool_context[:runtime_info_fn]
    if runtime_fn, do: prompt <> "\n\n" <> runtime_fn.(), else: prompt
```

- [ ] **Step 3: Pass extra_tool_context to build_system_prompt**

In `init/1` (line 72), change:

```elixir
    system_prompt = build_system_prompt(loader, opts.workspace, group, budget, opts.model)
```

to:

```elixir
    extra_tool_context = opts[:extra_tool_context] || %{}
    system_prompt = build_system_prompt(loader, opts.workspace, group, budget, opts.model, extra_tool_context)
```

In `handle_cast({:set_model, ...})` (line 142), change:

```elixir
    system_prompt = build_system_prompt(state.workspace_loader, state.workspace, state.group, budget, model)
```

to:

```elixir
    system_prompt = build_system_prompt(state.workspace_loader, state.workspace, state.group, budget, model, state.extra_tool_context)
```

- [ ] **Step 4: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix compile`

- [ ] **Step 5: Commit**

```
git add v3/apps/druzhok/lib/druzhok/instance/sup.ex v3/apps/pi_core/lib/pi_core/session.ex
git commit -m "inject runtime section with token budget into system prompt"
```

---

### Task 5: Add token limit input to dashboard

**Files:**
- Modify: `v3/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex`

- [ ] **Step 1: Add change_token_limit event handler**

Add after the existing `change_heartbeat` handler:

```elixir
  def handle_event("change_token_limit", %{"name" => name, "limit" => limit}, socket) do
    limit = case Integer.parse(limit) do
      {n, _} -> max(n, 0)
      :error -> 0
    end
    update_instance_field(name, %{daily_token_limit: limit})
    {:noreply, assign(socket, instances: list_instances())}
  end
```

- [ ] **Step 2: Add input field to instance header**

In the template, after the heartbeat `<form>` block (around line 551), add:

```html
            <form phx-change="change_token_limit" class="flex items-center gap-1">
              <input type="hidden" name="name" value={@selected} />
              <span class="text-[10px] text-gray-400">Tokens/day</span>
              <input type="number" name="limit" min="0" step="100000"
                     value={selected_field(@instances, @selected, :daily_token_limit) || 0}
                     placeholder="0 = unlimited"
                     class="w-20 border border-gray-300 rounded-lg px-2 py-1 text-xs focus:outline-none focus:ring-1 focus:ring-gray-900 font-mono" />
            </form>
```

- [ ] **Step 3: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix compile`

- [ ] **Step 4: Commit**

```
git add v3/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex
git commit -m "add daily token limit input to dashboard"
```
