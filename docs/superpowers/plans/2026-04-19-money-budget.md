# Money-Based Daily Budget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-bot daily USD budget (default $0.50), enforced by capturing OpenRouter per-request cost and blocking requests that exceed the daily cap. Lazy reset at midnight in the bot's timezone.

**Architecture:** `Druzhok.Budget` owns check/deduct/reset in cents and auto-resets lazily based on `instance.timezone`. `LlmFormat` requests `usage: {include: true}` from OpenRouter and extracts `usage.cost`. `ModelCatalog` provides a fallback price table for models where `usage.cost` is missing. Proxy controller blocks with HTTP 429 + Russian message on exhaustion.

**Tech Stack:** Elixir/Phoenix, Ecto/SQLite, Phoenix LiveView.

**Spec:** `docs/superpowers/specs/2026-04-19-money-budget-design.md`

---

## File Structure

**Migrations created:**
- `v4/druzhok/apps/druzhok/priv/repo/migrations/20260419000001_add_daily_budget_cents_to_instances.exs`
- `v4/druzhok/apps/druzhok/priv/repo/migrations/20260419000002_add_reset_at_to_budgets.exs`

**Files modified:**
- `v4/druzhok/apps/druzhok/lib/druzhok/instance.ex` — add `daily_budget_cents` field
- `v4/druzhok/apps/druzhok/lib/druzhok/budget.ex` — rewrite check/deduct/reset in cents with lazy daily reset
- `v4/druzhok/apps/druzhok/lib/druzhok/model_catalog.ex` — add `price_per_million/1` fallback table
- `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/llm_format.ex` — inject `usage: {include: true}`, add `extract_cost_cents/2`
- `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex` — wire cost capture into `meter/*`, 429 on exceeded
- `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex` — replace token field with money budget + usage display
- `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex` — handle `daily_budget_cents` form field

**Files created:**
- `v4/druzhok/apps/druzhok/test/druzhok/budget_test.exs`

---

## Task 1: Schema — add `daily_budget_cents` to `instances` and `reset_at` to `budgets`

**Files:**
- Create: `v4/druzhok/apps/druzhok/priv/repo/migrations/20260419000001_add_daily_budget_cents_to_instances.exs`
- Create: `v4/druzhok/apps/druzhok/priv/repo/migrations/20260419000002_add_reset_at_to_budgets.exs`
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/instance.ex` — add `field :daily_budget_cents, :integer, default: 0` and cast list

- [ ] **Step 1: Create the `daily_budget_cents` migration**

Write to `v4/druzhok/apps/druzhok/priv/repo/migrations/20260419000001_add_daily_budget_cents_to_instances.exs`:

```elixir
defmodule Druzhok.Repo.Migrations.AddDailyBudgetCentsToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :daily_budget_cents, :integer, null: false, default: 0
    end
  end
end
```

Note: default is `0` (unlimited) so existing bots are unaffected. New bots created via dashboard will get 50 via the form default in Task 6; managed-bot-provisioned ones inherit the DB default (0 = unlimited) until the owner sets one in the dashboard.

- [ ] **Step 2: Create the `reset_at` migration**

Write to `v4/druzhok/apps/druzhok/priv/repo/migrations/20260419000002_add_reset_at_to_budgets.exs`:

```elixir
defmodule Druzhok.Repo.Migrations.AddResetAtToBudgets do
  use Ecto.Migration

  def change do
    alter table(:budgets) do
      add :reset_at, :date
    end
  end
end
```

- [ ] **Step 3: Run migrations**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok
DATABASE_PATH=data/druzhok.db mix ecto.migrate
```

Expected: both migrations run green (`[info] === Running up 20260419000001...`).

- [ ] **Step 4: Add `daily_budget_cents` to Instance schema**

In `v4/druzhok/apps/druzhok/lib/druzhok/instance.ex`, find the line `field :website_hosting_enabled, :boolean, default: false` (around line 39) and add below it:

```elixir
    field :daily_budget_cents, :integer, default: 0
```

Then in the `cast/2` call (around line 48) add `:daily_budget_cents` to the atom list at the end, before `]):

```elixir
    |> cast(attrs, [:name, :telegram_token, :model, :workspace, :active, :heartbeat_interval, :owner_telegram_id, :sandbox, :timezone, :api_key, :daily_token_limit, :dream_hour, :language, :tenant_key, :bot_runtime, :on_demand_model, :mention_only, :reject_message, :welcome_message, :allowed_telegram_ids, :allowed_telegram_chats, :allow_all_telegram_users, :trigger_name, :image_model, :audio_model, :embedding_model, :heartbeat_active_start, :heartbeat_active_end, :heartbeat_target, :fallback_models, :dreaming, :group_sessions_per_user, :group_shared_memory, :website_hosting_enabled, :daily_budget_cents])
```

- [ ] **Step 5: Verify compile + existing tests still pass**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok
mix compile 2>&1 | tail -3
mix test apps/druzhok/test 2>&1 | tail -5
```

Expected: compile clean; all tests pass (same count as before).

- [ ] **Step 6: Commit**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add v4/druzhok/apps/druzhok/priv/repo/migrations/20260419000001_add_daily_budget_cents_to_instances.exs \
        v4/druzhok/apps/druzhok/priv/repo/migrations/20260419000002_add_reset_at_to_budgets.exs \
        v4/druzhok/apps/druzhok/lib/druzhok/instance.ex
git commit -m "budget: add daily_budget_cents column + reset_at on budgets"
```

---

## Task 2: `Druzhok.Budget` rewrite — cents, lazy daily reset, timezone-aware

**Files:**
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/budget.ex` — replace `check/1` and `deduct/2`
- Create: `v4/druzhok/apps/druzhok/test/druzhok/budget_test.exs`

- [ ] **Step 1: Write the failing tests**

Write to `v4/druzhok/apps/druzhok/test/druzhok/budget_test.exs`:

```elixir
defmodule Druzhok.BudgetTest do
  use ExUnit.Case
  alias Druzhok.{Budget, Instance, Repo}

  setup do
    # Rollback-on-exit sandbox is not configured; use a plain insert + cleanup.
    name = "budget-test-#{System.unique_integer([:positive])}"
    {:ok, instance} =
      %Instance{}
      |> Instance.changeset(%{
        name: name,
        model: "xiaomi/mimo-v2-pro",
        workspace: "/tmp/#{name}/workspace",
        timezone: "UTC",
        daily_budget_cents: 100
      })
      |> Repo.insert()

    on_exit(fn ->
      Repo.delete_all(from(b in Budget, where: b.instance_id == ^instance.id))
      Repo.delete(instance)
    end)

    %{instance: instance}
  end

  describe "check/1" do
    test "returns :unlimited when daily_budget_cents is 0", %{instance: instance} do
      {:ok, _} =
        instance
        |> Instance.changeset(%{daily_budget_cents: 0})
        |> Repo.update()

      assert Budget.check(instance.id) == {:ok, :unlimited}
    end

    test "returns :ok when spent_today < daily_budget_cents", %{instance: instance} do
      Budget.deduct(instance.id, 30)
      assert {:ok, remaining} = Budget.check(instance.id)
      assert remaining == 70
    end

    test "returns {:error, :exceeded} when spent_today >= daily_budget_cents", %{instance: instance} do
      Budget.deduct(instance.id, 100)
      assert Budget.check(instance.id) == {:error, :exceeded}
    end
  end

  describe "lazy reset" do
    test "resets balance when reset_at differs from today-in-tz", %{instance: instance} do
      Budget.deduct(instance.id, 80)
      yesterday = Date.add(Date.utc_today(), -1)
      Repo.update_all(
        from(b in Budget, where: b.instance_id == ^instance.id),
        set: [reset_at: yesterday]
      )

      assert {:ok, 100} = Budget.check(instance.id)

      reloaded = Repo.get_by(Budget, instance_id: instance.id)
      assert reloaded.balance == 0
      assert reloaded.reset_at == Date.utc_today()
    end

    test "respects non-UTC timezone", %{instance: instance} do
      {:ok, instance} =
        instance
        |> Instance.changeset(%{timezone: "Europe/Amsterdam"})
        |> Repo.update()

      Budget.deduct(instance.id, 50)
      today_ams = DateTime.now!("Europe/Amsterdam") |> DateTime.to_date()
      reloaded = Repo.get_by(Budget, instance_id: instance.id)
      assert reloaded.reset_at == today_ams
    end
  end

  describe "deduct/2" do
    test "increments balance and lifetime_used", %{instance: instance} do
      {:ok, _} = Budget.deduct(instance.id, 25)
      {:ok, _} = Budget.deduct(instance.id, 10)
      b = Repo.get_by(Budget, instance_id: instance.id)
      assert b.balance == 35
      assert b.lifetime_used == 35
    end

    test "is a no-op for non-positive amounts", %{instance: instance} do
      Budget.deduct(instance.id, 20)
      Budget.deduct(instance.id, 0)
      Budget.deduct(instance.id, -5)
      b = Repo.get_by(Budget, instance_id: instance.id)
      assert b.balance == 20
    end
  end
end
```

Also add `import Ecto.Query` at the top of the file — between `use ExUnit.Case` and `alias`:

```elixir
defmodule Druzhok.BudgetTest do
  use ExUnit.Case
  import Ecto.Query
  alias Druzhok.{Budget, Instance, Repo}
```

- [ ] **Step 2: Run tests — they must fail**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok
mix test apps/druzhok/test/druzhok/budget_test.exs 2>&1 | tail -20
```

Expected: multiple failures. The existing `Budget.check/1` compares `daily_token_limit`, not `daily_budget_cents`; there is no `reset_at` logic.

- [ ] **Step 3: Rewrite `Druzhok.Budget`**

Replace the content of `v4/druzhok/apps/druzhok/lib/druzhok/budget.ex` with:

```elixir
defmodule Druzhok.Budget do
  @moduledoc """
  Per-bot daily USD budget in cents.

  Budget.balance stores cents spent *today* (not remaining). The limit
  lives on `instance.daily_budget_cents`. Value 0 = unlimited.

  Daily reset is lazy: every `check/1` call compares `budget.reset_at` to
  today-in-tz (using `instance.timezone`). If different, `balance` is
  zeroed and `reset_at` is advanced. No cron required.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Druzhok.{Instance, Repo}

  schema "budgets" do
    belongs_to :instance, Druzhok.Instance
    field :balance, :integer, default: 0
    field :lifetime_used, :integer, default: 0
    field :reset_at, :date
    timestamps()
  end

  def changeset(budget, attrs) do
    budget
    |> cast(attrs, [:instance_id, :balance, :lifetime_used, :reset_at])
    |> validate_required([:instance_id])
    |> unique_constraint(:instance_id)
  end

  @doc """
  Returns `{:ok, remaining_cents}`, `{:ok, :unlimited}`, or `{:error, :exceeded}`.
  Lazily resets the daily counter when the reset_at date differs from today-in-tz.
  """
  def check(instance_id) do
    case Repo.get(Instance, instance_id) do
      nil ->
        {:error, :not_found}

      %Instance{daily_budget_cents: 0} ->
        {:ok, :unlimited}

      %Instance{daily_budget_cents: limit} = instance ->
        budget = get_or_create_with_reset(instance)

        if budget.balance >= limit do
          {:error, :exceeded}
        else
          {:ok, limit - budget.balance}
        end
    end
  end

  @doc """
  Adds `cents` to today's spend and lifetime total. No-op for zero/negative.
  """
  def deduct(instance_id, cents) when is_integer(cents) and cents > 0 do
    instance = Repo.get(Instance, instance_id)
    budget = get_or_create_with_reset(instance)

    budget
    |> changeset(%{
      balance: budget.balance + cents,
      lifetime_used: budget.lifetime_used + cents
    })
    |> Repo.update()
  end

  def deduct(_instance_id, _cents), do: :ok

  @doc """
  Returns cents spent today for display in dashboard.
  """
  def spent_today_cents(instance_id) do
    case Repo.get(Instance, instance_id) do
      nil ->
        0

      instance ->
        budget = get_or_create_with_reset(instance)
        budget.balance
    end
  end

  # --- Private ---

  defp get_or_create_with_reset(%Instance{} = instance) do
    today = today_in_tz(instance.timezone || "UTC")

    case Repo.get_by(__MODULE__, instance_id: instance.id) do
      nil ->
        %__MODULE__{}
        |> changeset(%{instance_id: instance.id, balance: 0, reset_at: today})
        |> Repo.insert!()

      %__MODULE__{reset_at: ^today} = budget ->
        budget

      budget ->
        budget
        |> changeset(%{balance: 0, reset_at: today})
        |> Repo.update!()
    end
  end

  defp today_in_tz(tz) do
    case DateTime.now(tz) do
      {:ok, dt} -> DateTime.to_date(dt)
      _ -> Date.utc_today()
    end
  end
end
```

- [ ] **Step 4: Run tests — they must pass**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok
mix test apps/druzhok/test/druzhok/budget_test.exs 2>&1 | tail -10
```

Expected: `N tests, 0 failures` (should be 6 tests passing).

- [ ] **Step 5: Commit**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add v4/druzhok/apps/druzhok/lib/druzhok/budget.ex v4/druzhok/apps/druzhok/test/druzhok/budget_test.exs
git commit -m "budget: rewrite in cents with lazy daily reset in bot timezone"
```

---

## Task 3: `ModelCatalog.price_per_million/1` — fallback price table

**Files:**
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/model_catalog.ex` — add `price_per_million/1`
- Modify: `v4/druzhok/apps/druzhok/test/druzhok/model_info_test.exs` (create alongside or add a new test file)

- [ ] **Step 1: Write the failing test**

Create `v4/druzhok/apps/druzhok/test/druzhok/model_catalog_price_test.exs`:

```elixir
defmodule Druzhok.ModelCatalogPriceTest do
  use ExUnit.Case, async: true
  alias Druzhok.ModelCatalog

  describe "price_per_million/1" do
    test "returns known prices for common models" do
      assert %{input: 10, output: 150} = ModelCatalog.price_per_million("xiaomi/mimo-v2-pro")
      assert %{input: 10, output: 40} = ModelCatalog.price_per_million("google/gemini-2.5-flash-lite")
      assert %{input: 300, output: 1500} = ModelCatalog.price_per_million("anthropic/claude-sonnet-4-6")
    end

    test "returns safe zeros for unknown models" do
      assert %{input: 0, output: 0} = ModelCatalog.price_per_million("nonexistent/model")
      assert %{input: 0, output: 0} = ModelCatalog.price_per_million(nil)
    end
  end
end
```

- [ ] **Step 2: Run test — must fail**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok
mix test apps/druzhok/test/druzhok/model_catalog_price_test.exs
```

Expected: fails with `UndefinedFunctionError: function Druzhok.ModelCatalog.price_per_million/1 is undefined`.

- [ ] **Step 3: Add `price_per_million/1` to ModelCatalog**

In `v4/druzhok/apps/druzhok/lib/druzhok/model_catalog.ex`, add this block at the end of the module (before the final `end`):

```elixir
  # Fallback prices used only when OpenRouter's usage.cost is missing from
  # the response. Values are cents per 1,000,000 tokens. Check
  # https://openrouter.ai/models for current published prices.
  @prices %{
    "xiaomi/mimo-v2-pro" => %{input: 10, output: 150},
    "google/gemini-2.5-flash-lite" => %{input: 10, output: 40},
    "google/gemini-3-flash-preview" => %{input: 30, output: 120},
    "anthropic/claude-sonnet-4-6" => %{input: 300, output: 1500},
    "openai/gpt-5.4-nano" => %{input: 5, output: 20},
    "openai/gpt-5.4-mini" => %{input: 25, output: 100},
    "qwen/qwen3.5-flash" => %{input: 7, output: 28},
    "deepseek/deepseek-v3.2" => %{input: 30, output: 140},
  }

  def price_per_million(nil), do: %{input: 0, output: 0}
  def price_per_million(model), do: Map.get(@prices, model, %{input: 0, output: 0})
```

- [ ] **Step 4: Run tests — must pass**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok
mix test apps/druzhok/test/druzhok/model_catalog_price_test.exs
```

Expected: `2 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add v4/druzhok/apps/druzhok/lib/druzhok/model_catalog.ex v4/druzhok/apps/druzhok/test/druzhok/model_catalog_price_test.exs
git commit -m "model_catalog: add price_per_million fallback table"
```

---

## Task 4: `LlmFormat` — request `usage: {include: true}` and extract cost cents

**Files:**
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/llm_format.ex`

Note: the existing `prepare_body/1` already injects `max_tokens`, `reasoning`, and strips images for non-vision models. We extend it and add `extract_cost_cents/2`.

- [ ] **Step 1: Update `prepare_body/1` to inject `usage: {include: true}`**

In `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/llm_format.ex`, find the `prepare_body/1` function. Locate:

```elixir
    body =
      body
      |> Map.put_new("max_tokens", @default_max_tokens)
      |> apply_reasoning_override(model)
```

Change to:

```elixir
    body =
      body
      |> Map.put_new("max_tokens", @default_max_tokens)
      |> Map.put_new("usage", %{"include" => true})
      |> apply_reasoning_override(model)
```

- [ ] **Step 2: Add `extract_cost_cents/2` helper**

At the bottom of the same module (before the final `end`), add:

```elixir
  @doc """
  Extracts cost in cents from an OpenRouter response body (parsed map).

  Primary path: OpenRouter returns `usage.cost` (USD float) when
  `usage.include=true` was set in the request. Secondary path: compute
  from prompt/completion tokens using `Druzhok.ModelCatalog.price_per_million/1`
  as a fallback. Returns 0 if neither is available.

  `model` is passed separately because the response body's "model" field
  can be a resolved variant (e.g. provider-specific suffix) that misses
  the price table.
  """
  def extract_cost_cents(decoded, model) when is_map(decoded) do
    case get_in(decoded, ["usage", "cost"]) do
      nil -> fallback_cost_cents(decoded, model)
      cost when is_number(cost) -> round(cost * 100)
      _ -> fallback_cost_cents(decoded, model)
    end
  end

  def extract_cost_cents(_, _), do: 0

  defp fallback_cost_cents(decoded, model) do
    prompt = get_in(decoded, ["usage", "prompt_tokens"]) || 0
    completion = get_in(decoded, ["usage", "completion_tokens"]) || 0

    if prompt + completion == 0 do
      0
    else
      %{input: in_price, output: out_price} = Druzhok.ModelCatalog.price_per_million(model)
      round(prompt * in_price / 1_000_000 + completion * out_price / 1_000_000)
    end
  end
```

- [ ] **Step 3: Add a test for the helper**

Create `v4/druzhok/apps/druzhok_web/test/druzhok_web_web/llm_format_test.exs`:

```elixir
defmodule DruzhokWebWeb.LlmFormatTest do
  use ExUnit.Case, async: true
  alias DruzhokWebWeb.LlmFormat

  describe "prepare_body/1" do
    test "injects usage.include=true when absent" do
      body = LlmFormat.prepare_body(%{"model" => "xiaomi/mimo-v2-pro", "messages" => []})
      assert body["usage"] == %{"include" => true}
    end

    test "does not override an explicit usage option" do
      body = LlmFormat.prepare_body(%{
        "model" => "x",
        "messages" => [],
        "usage" => %{"include" => false, "extra" => "preserved"}
      })
      assert body["usage"] == %{"include" => false, "extra" => "preserved"}
    end
  end

  describe "extract_cost_cents/2" do
    test "reads usage.cost and converts USD→cents with rounding" do
      body = %{"usage" => %{"cost" => 0.00235, "prompt_tokens" => 100, "completion_tokens" => 20}}
      assert LlmFormat.extract_cost_cents(body, "any") == 0
      # 0.00235 * 100 = 0.235 → rounds to 0
    end

    test "reads non-trivial usage.cost" do
      body = %{"usage" => %{"cost" => 0.1234}}
      assert LlmFormat.extract_cost_cents(body, "any") == 12
    end

    test "falls back to ModelCatalog price when usage.cost is missing" do
      body = %{"usage" => %{"prompt_tokens" => 1_000_000, "completion_tokens" => 0}}
      assert LlmFormat.extract_cost_cents(body, "xiaomi/mimo-v2-pro") == 10
    end

    test "returns 0 when no usage at all" do
      assert LlmFormat.extract_cost_cents(%{}, "x") == 0
      assert LlmFormat.extract_cost_cents(nil, "x") == 0
    end
  end
end
```

- [ ] **Step 4: Run tests**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok
mix test apps/druzhok_web/test/druzhok_web_web/llm_format_test.exs
```

Expected: `6 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/llm_format.ex \
        v4/druzhok/apps/druzhok_web/test/druzhok_web_web/llm_format_test.exs
git commit -m "llm_format: request usage.include and add extract_cost_cents"
```

---

## Task 5: Proxy wiring — capture cost, deduct from budget, return 429 on exceeded

**Files:**
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex`

This task does three things in one file:
1. Replace `json_error(..., "Token budget exceeded", ...)` at line 17 with a Russian, money-based message computed from instance data.
2. Capture cost in all three paths (`sync_proxy`, `stream_proxy`, `fake_stream_proxy`) and pass it to `meter/*`.
3. Update `meter/*` to write `cost_cents` into `usage_logs` and call `Budget.deduct(instance_id, cost_cents)`.

- [ ] **Step 1: Update the 429 path with a friendly Russian message**

In `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex`, find the `chat_completions/2` function (around line 9). Locate:

```elixir
    case Budget.check(instance.id) do
      {:error, :exceeded} ->
        json_error(conn, 429, "Token budget exceeded", "insufficient_quota")
```

Replace with:

```elixir
    case Budget.check(instance.id) do
      {:error, :exceeded} ->
        json_error(conn, 429, budget_exceeded_message(instance), "budget_exceeded")
```

And add this private helper at the bottom of the module (before the final `end`):

```elixir
  defp budget_exceeded_message(instance) do
    limit_dollars = :io_lib.format("~.2f", [(instance.daily_budget_cents || 0) / 100]) |> IO.iodata_to_binary()
    tz = instance.timezone || "UTC"

    reset_clock =
      case DateTime.now(tz) do
        {:ok, dt} ->
          tomorrow = Date.add(DateTime.to_date(dt), 1)
          reset_dt = DateTime.new!(tomorrow, ~T[00:00:00], tz)
          diff_min = div(DateTime.diff(reset_dt, dt, :second), 60)
          hours = div(diff_min, 60)
          mins = rem(diff_min, 60)
          "через #{hours}ч #{mins}м"

        _ ->
          "в 00:00 UTC"
      end

    "Бюджет на сегодня исчерпан. Лимит $#{limit_dollars}. Сбросится #{reset_clock}."
  end
```

- [ ] **Step 2: Thread `cost_cents` through the proxy paths**

Update `sync_proxy/7` — find:

```elixir
  defp sync_proxy(conn, instance, url, headers, body, model, started_at) do
    request = Finch.build(:post, url, headers, Jason.encode!(body))

    case Finch.request(request, Druzhok.Finch, receive_timeout: 120_000) do
      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        decoded = Jason.decode!(resp_body)
        usage = LlmFormat.extract_usage(decoded)
        response_preview = get_in(decoded, ["choices", Access.at(0), "message", "content"])
        meter(instance, usage, model, started_at, body, response_preview)
```

Change the `meter/*` call (last line above) to:

```elixir
        cost_cents = LlmFormat.extract_cost_cents(decoded, model)
        meter(instance, usage, model, started_at, body, response_preview, cost_cents)
```

Update `stream_proxy/7` — find the line right after the stream completes (around line 85):

```elixir
    usage = Process.get(usage_ref, %{prompt_tokens: 0, completion_tokens: 0})
    meter(instance, usage, model, started_at, body, nil)
```

Change to:

```elixir
    usage = Process.get(usage_ref, %{prompt_tokens: 0, completion_tokens: 0})
    cost_cents = Process.get({usage_ref, :cost}, 0)
    meter(instance, usage, model, started_at, body, nil, cost_cents)
```

And inside the stream-chunk parser (the `for line <- String.split(data, "\n")...` block), update the match to extract cost too. Replace:

```elixir
            case Jason.decode(json_str) do
              {:ok, %{"usage" => usage}} when is_map(usage) ->
                Process.put(usage_ref, LlmFormat.extract_usage(%{"usage" => usage}))
              _ -> :ok
            end
```

with:

```elixir
            case Jason.decode(json_str) do
              {:ok, %{"usage" => usage} = chunk} when is_map(usage) ->
                Process.put(usage_ref, LlmFormat.extract_usage(%{"usage" => usage}))
                Process.put({usage_ref, :cost}, LlmFormat.extract_cost_cents(chunk, model))
              _ -> :ok
            end
```

Update `fake_stream_proxy/7` — find the `meter(instance, usage, model, started_at, body, content)` line (around line 73) and change to:

```elixir
        cost_cents = LlmFormat.extract_cost_cents(decoded, model)
        meter(instance, usage, model, started_at, body, content, cost_cents)
```

- [ ] **Step 3: Update `meter/*` to persist cost and deduct from budget**

Find `meter/*` (around line 94). Replace the whole function with:

```elixir
  defp meter(instance, usage, model, started_at, request_body, response_preview, cost_cents \\ 0) do
    total = usage.prompt_tokens + usage.completion_tokens

    if total > 0 do
      latency = System.monotonic_time(:millisecond) - started_at
      Budget.deduct(instance.id, cost_cents)

      prompt_preview = case request_body["messages"] do
        [_ | _] = msgs ->
          content = msgs |> List.last() |> Map.get("content", "")
          case content do
            text when is_binary(text) -> String.slice(text, 0, 500)
            parts when is_list(parts) ->
              parts
              |> Enum.filter(&(&1["type"] == "text"))
              |> Enum.map_join(" ", &(&1["text"] || ""))
              |> String.slice(0, 500)
            _ -> nil
          end
        _ -> nil
      end

      resp_preview = if response_preview, do: String.slice(response_preview, 0, 500), else: nil

      Usage.log(%{
        instance_id: instance.id,
        model: model,
        prompt_tokens: usage.prompt_tokens,
        completion_tokens: usage.completion_tokens,
        total_tokens: total,
        cost_cents: cost_cents,
        request_type: "chat",
        requested_model: model,
        resolved_model: model,
        provider: "openrouter",
        latency_ms: latency,
        prompt_preview: prompt_preview,
        response_preview: resp_preview,
        request_body: Jason.encode!(request_body),
      })
    end
  end
```

Two changes: added `cost_cents \\ 0` param with default (keeps callers that don't pass it compiling), and switched `Budget.deduct(instance.id, total)` to `Budget.deduct(instance.id, cost_cents)`.

- [ ] **Step 4: Compile and smoke-test locally**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok
mix compile 2>&1 | tail -3
mix test apps/druzhok_web/test 2>&1 | tail -5
```

Expected: compile clean. Tests passing (no new test here — behaviour is covered by integration via remote smoke test in Task 7).

- [ ] **Step 5: Commit**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex
git commit -m "proxy: capture cost_cents, deduct from budget, 429 on exceeded"
```

---

## Task 6: Dashboard settings — money budget input + today's usage display

**Files:**
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex`
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex`

- [ ] **Step 1: Replace the token limit field with money budget + usage**

In `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex`, find (around line 35-41):

```elixir
              <div class="grid grid-cols-2 gap-2">
                <div>
                  <label class="block text-[10px] text-muted mb-0.5">Token limit</label>
                  <input type="number" name="token_limit" min="0" step="100000" phx-debounce="blur"
                         value={@instance[:daily_token_limit] || 0}
                         class="w-full border border-line2 rounded px-2 py-1 text-xs font-mono" />
                </div>
```

Replace with:

```elixir
              <div class="grid grid-cols-2 gap-2">
                <div>
                  <label class="block text-[10px] text-muted mb-0.5">Daily budget ($)</label>
                  <input type="number" name="daily_budget_dollars" min="0" step="0.10" phx-debounce="blur"
                         value={budget_dollars(@instance)}
                         class="w-full border border-line2 rounded px-2 py-1 text-xs font-mono" />
                  <div class="text-[10px] text-muted mt-0.5 font-mono"><%= usage_line(@instance) %></div>
                  <div class="h-1 bg-line2 rounded mt-1 overflow-hidden">
                    <div class={"h-full #{usage_bar_color(@instance)}"} style={"width: #{usage_bar_width(@instance)}%"}></div>
                  </div>
                </div>
```

- [ ] **Step 2: Add the helper functions to the component**

At the bottom of `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex` (before the final `end`), add:

```elixir
  defp budget_dollars(instance) do
    cents = instance[:daily_budget_cents] || 0
    :io_lib.format("~.2f", [cents / 100]) |> IO.iodata_to_binary()
  end

  defp usage_line(instance) do
    limit = instance[:daily_budget_cents] || 0
    spent = Druzhok.Budget.spent_today_cents(instance[:id] || instance.id)

    cond do
      limit == 0 ->
        "Unlimited — #{dollars(spent)} spent today"

      limit > 0 ->
        pct = round(spent * 100 / limit)
        "#{dollars(spent)} / #{dollars(limit)} (#{pct}%)"
    end
  end

  defp usage_bar_width(instance) do
    limit = instance[:daily_budget_cents] || 0
    spent = Druzhok.Budget.spent_today_cents(instance[:id] || instance.id)

    if limit == 0, do: 0, else: min(round(spent * 100 / limit), 100)
  end

  defp usage_bar_color(instance) do
    limit = instance[:daily_budget_cents] || 0
    spent = Druzhok.Budget.spent_today_cents(instance[:id] || instance.id)
    pct = if limit == 0, do: 0, else: spent * 100 / limit

    cond do
      pct >= 80 -> "bg-red-500"
      pct >= 50 -> "bg-yellow-500"
      true -> "bg-green-500"
    end
  end

  defp dollars(cents) do
    "$" <> (:io_lib.format("~.2f", [cents / 100]) |> IO.iodata_to_binary())
  end
```

- [ ] **Step 3: Update the form-save path in `settings_live.ex`**

In `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex`, find the section that handles `token_limit` (around line 295-299 based on the earlier grep):

```elixir
      daily_token_limit: token_limit,
```

Find the full `handle_event` block for save (search for `"save"` or `token_limit` to locate). Assume the block currently looks like:

```elixir
  def handle_event("save", params, socket) do
    token_limit = String.to_integer(params["token_limit"] || "0")
    # ...
    attrs = %{
      # ... other fields ...
      daily_token_limit: token_limit,
      # ...
    }
    # ...
  end
```

Replace the `token_limit` lines with:

```elixir
    dollars_str = params["daily_budget_dollars"] || "0"
    daily_budget_cents =
      case Float.parse(dollars_str) do
        {value, _} -> round(value * 100)
        :error -> 0
      end
```

And in the `attrs` map replace `daily_token_limit: token_limit,` with:

```elixir
      daily_budget_cents: daily_budget_cents,
```

**Important:** If other callers in this file still reference `token_limit`, update them. Grep first:

```bash
grep -n "token_limit\|daily_token_limit" v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex
```

- [ ] **Step 4: Compile and run tests**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok
mix compile 2>&1 | tail -3
mix test 2>&1 | tail -5
```

Expected: compile clean, all tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex \
        v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex
git commit -m "dashboard: money-based daily budget input + today usage display"
```

---

## Task 7: Deploy + smoke test

**Files:** none (deployment only).

- [ ] **Step 1: Push and deploy druzhok**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git push origin main
ssh -l igor 158.160.78.230 'cd ~/druzhok && git pull && source ~/.bashrc; . ~/.asdf/asdf.sh; cd v4/druzhok && mix compile 2>&1 | tail -3 && DATABASE_PATH=/home/igor/druzhok-data/v4-druzhok.db mix ecto.migrate && sudo systemctl restart druzhok && sleep 3 && systemctl is-active druzhok'
```

Expected: both migrations run, `active`.

- [ ] **Step 2: Verify existing bots stay unlimited**

```bash
ssh -l igor 158.160.78.230 'sqlite3 /home/igor/druzhok-data/v4-druzhok.db "SELECT name, daily_budget_cents FROM instances"'
```

Expected: every row shows `0` (unlimited). Existing bots continue working as before.

- [ ] **Step 3: Verify cost is captured in `usage_logs`**

Send a test message to any bot via Telegram, then:

```bash
ssh -l igor 158.160.78.230 'sqlite3 /home/igor/druzhok-data/v4-druzhok.db "SELECT id, model, completion_tokens, cost_cents FROM usage_logs ORDER BY id DESC LIMIT 3"'
```

Expected: the most recent row has `cost_cents > 0`. If all three rows have `cost_cents = 0`, either OpenRouter didn't include `usage.cost` (check with: `sqlite3 ... "SELECT request_body FROM usage_logs ORDER BY id DESC LIMIT 1"` — verify `"usage":{"include":true}` is present) or the fallback path isn't firing.

- [ ] **Step 4: Verify the exceeded path**

Pick a bot (e.g. igorhermes), set a tiny budget:

```bash
ssh -l igor 158.160.78.230 'sqlite3 /home/igor/druzhok-data/v4-druzhok.db "UPDATE instances SET daily_budget_cents=1 WHERE name=\"igorhermes\""'
```

Send ~2 messages to that bot. Expected: second or third message fails with a user-visible error starting with `Бюджет на сегодня исчерпан. Лимит $0.01.`

Reset when done testing:

```bash
ssh -l igor 158.160.78.230 'sqlite3 /home/igor/druzhok-data/v4-druzhok.db "UPDATE instances SET daily_budget_cents=0 WHERE name=\"igorhermes\""; sqlite3 /home/igor/druzhok-data/v4-druzhok.db "UPDATE budgets SET balance=0 WHERE instance_id=(SELECT id FROM instances WHERE name=\"igorhermes\")"'
```

- [ ] **Step 5: Verify the dashboard UI**

Open `https://oldey.dev/bots/igorhermes/settings` in a browser. Expected:
- "Daily budget ($)" field shows `0.00` (or whatever was set)
- Below it: `Unlimited — $X.XX spent today` (if 0) or `$X.XX / $Y.YY (Z%)` + progress bar (if non-zero)
- Typing a new value (e.g. `0.50`) and blurring saves it — check DB: `daily_budget_cents=50`

---

## Self-Review Notes

- **Spec coverage:** every component in the spec is mapped:
  - Schema change → Task 1
  - `Druzhok.Budget` rewrite (cents, lazy reset, tz-aware) → Task 2
  - `ModelCatalog.price_per_million/1` fallback → Task 3
  - `LlmFormat` injection + cost extraction → Task 4
  - Proxy 429 + meter wiring → Task 5
  - Dashboard UI → Task 6
  - Migration/rollback → Task 7 (smoke-test covers rollback path by confirming existing bots unaffected)
- **Legacy `daily_token_limit` column:** intentionally left in the DB per the spec's "Out of Scope" section (drop in a later cleanup). The dashboard no longer exposes it.
- **Non-UTC timezone test** (Task 2, Step 1) compares the stored `reset_at` to today in Amsterdam — guards against a regression where UTC is hard-coded in the reset check.
- **Cost-capture double-counting check:** `meter/*` only deducts once per request (one call site per path: sync, stream, fake-stream). The default `cost_cents \\ 0` keeps existing non-chat code paths (e.g. audio transcription may call `meter` without a cost) from accidentally passing `nil`.
