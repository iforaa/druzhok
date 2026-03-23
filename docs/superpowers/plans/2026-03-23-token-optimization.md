# Token Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a layered token budget system to Druzhok v3 that proportionally allocates context window space to system prompts, tool definitions, conversation history, and tool results — reducing API costs across all model sizes.

**Architecture:** A `TokenBudget` struct computed per-session from model metadata and dashboard-configurable ratios. Each budget layer (system prompt, history, tool results) enforces its own cap independently. All hyperparameters stored in DB via `Druzhok.Settings`, editable from the dashboard.

**Tech Stack:** Elixir/OTP, Phoenix LiveView, Ecto/SQLite, ExUnit

**Spec:** `docs/superpowers/specs/2026-03-23-token-optimization-design.md`

---

## File Structure

### New files (pi_core)
- `v3/apps/pi_core/lib/pi_core/token_estimator.ex` — byte_size/4 token estimation
- `v3/apps/pi_core/lib/pi_core/token_budget.ex` — budget struct + compute
- `v3/apps/pi_core/lib/pi_core/truncate.ex` — head+tail truncation helper
- `v3/apps/pi_core/lib/pi_core/prompt_budget.ex` — budget-aware system prompt builder
- `v3/apps/pi_core/lib/pi_core/model_info.ex` — behaviour for model metadata lookup
- `v3/apps/pi_core/lib/pi_core/transform.ex` — message transforms (reasoning strip, tool compaction)
- `v3/apps/pi_core/test/pi_core/token_estimator_test.exs`
- `v3/apps/pi_core/test/pi_core/token_budget_test.exs`
- `v3/apps/pi_core/test/pi_core/truncate_test.exs`
- `v3/apps/pi_core/test/pi_core/prompt_budget_test.exs`
- `v3/apps/pi_core/test/pi_core/transform_test.exs`

### New files (druzhok)
- `v3/apps/druzhok/lib/druzhok/model_info.ex` — DB-backed ModelInfo implementation
- `v3/apps/druzhok/priv/repo/migrations/20260323000001_add_context_window_to_models.exs`
- `v3/apps/druzhok/test/druzhok/model_info_test.exs`

### New files (druzhok_web)
- `v3/apps/druzhok_web/lib/druzhok_web_web/live/models_live.ex` — model profiles CRUD page

### Modified files
- `v3/apps/pi_core/lib/pi_core/loop.ex` — add transform_messages, budget-aware truncation
- `v3/apps/pi_core/lib/pi_core/compaction.ex` — token-based trigger, iterative summarization
- `v3/apps/pi_core/lib/pi_core/session.ex` — add budget field, pass to loop/compaction, model-change recompute
- `v3/apps/pi_core/lib/pi_core/session_store.ex` — pre-persistence size guard
- `v3/apps/pi_core/lib/pi_core/config.ex` — add budget defaults, support DB override callback
- `v3/apps/pi_core/lib/pi_core/workspace_loader.ex` — delegate to PromptBudget
- `v3/apps/druzhok/lib/druzhok/model.ex` — add context_window, supports_reasoning, supports_tools fields
- `v3/apps/druzhok/lib/druzhok/instance/sup.ex` — inject model_info_fn into session config
- `v3/apps/druzhok_web/lib/druzhok_web_web/router.ex` — add /models route
- `v3/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex` — add budget ratio settings

---

### Task 1: TokenEstimator

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/token_estimator.ex`
- Create: `v3/apps/pi_core/test/pi_core/token_estimator_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# v3/apps/pi_core/test/pi_core/token_estimator_test.exs
defmodule PiCore.TokenEstimatorTest do
  use ExUnit.Case

  alias PiCore.TokenEstimator
  alias PiCore.Loop.Message

  test "estimate/1 returns byte_size / 4" do
    assert TokenEstimator.estimate("hello") == 2  # 5 bytes / 4 = 1.25 -> ceil = 2
  end

  test "estimate/1 handles Cyrillic text conservatively" do
    # "Привет" = 12 bytes in UTF-8 (6 chars × 2 bytes)
    assert TokenEstimator.estimate("Привет") == 3  # 12 / 4 = 3
  end

  test "estimate/1 returns 0 for nil" do
    assert TokenEstimator.estimate(nil) == 0
  end

  test "estimate/1 returns 0 for empty string" do
    assert TokenEstimator.estimate("") == 0
  end

  test "estimate_message/1 counts content" do
    msg = %Message{role: "user", content: "Hello world"}
    assert TokenEstimator.estimate_message(msg) > 0
  end

  test "estimate_message/1 counts tool call arguments" do
    msg = %Message{
      role: "assistant",
      content: "",
      tool_calls: [
        %{"id" => "1", "function" => %{"name" => "read", "arguments" => ~s({"path":"test.txt"})}}
      ]
    }
    tokens = TokenEstimator.estimate_message(msg)
    assert tokens > 0
  end

  test "estimate_messages/1 sums all messages" do
    messages = [
      %Message{role: "user", content: "Hello"},
      %Message{role: "assistant", content: "Hi there"}
    ]
    total = TokenEstimator.estimate_messages(messages)
    assert total == TokenEstimator.estimate_message(Enum.at(messages, 0)) +
                     TokenEstimator.estimate_message(Enum.at(messages, 1))
  end

  test "estimate_tools/1 estimates OpenAI tool schemas" do
    tools = [
      %{"type" => "function", "function" => %{
        "name" => "bash",
        "description" => "Execute a shell command",
        "parameters" => %{"type" => "object", "properties" => %{"command" => %{"type" => "string"}}, "required" => ["command"]}
      }}
    ]
    assert TokenEstimator.estimate_tools(tools) > 0
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/token_estimator_test.exs`
Expected: compilation error — `PiCore.TokenEstimator` not found

- [ ] **Step 3: Write the implementation**

```elixir
# v3/apps/pi_core/lib/pi_core/token_estimator.ex
defmodule PiCore.TokenEstimator do
  @moduledoc """
  Token estimation using byte_size / divisor heuristic.
  Conservative for non-Latin text (Cyrillic = 2 bytes/char in UTF-8).
  """

  alias PiCore.Loop.Message

  @default_divisor 4

  def estimate(nil), do: 0
  def estimate(""), do: 0
  def estimate(text) when is_binary(text) do
    div(byte_size(text) + @default_divisor - 1, divisor())
  end

  def estimate_message(%Message{} = msg) do
    content_tokens = estimate(msg.content)
    tool_tokens = estimate_tool_calls(msg.tool_calls)
    content_tokens + tool_tokens
  end
  def estimate_message(%{} = msg) do
    content_tokens = estimate(msg[:content] || msg["content"])
    tool_tokens = estimate_tool_calls(msg[:tool_calls] || msg["tool_calls"])
    content_tokens + tool_tokens
  end

  def estimate_messages(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc -> acc + estimate_message(msg) end)
  end

  def estimate_tools(tools) when is_list(tools) do
    tools
    |> Jason.encode!()
    |> estimate()
  end

  defp estimate_tool_calls(nil), do: 0
  defp estimate_tool_calls([]), do: 0
  defp estimate_tool_calls(calls) do
    Enum.reduce(calls, 0, fn call, acc ->
      name = get_in(call, ["function", "name"]) || ""
      args = get_in(call, ["function", "arguments"]) || ""
      acc + estimate(name) + estimate(args)
    end)
  end

  defp divisor do
    Application.get_env(:pi_core, :token_estimation_divisor, @default_divisor)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/token_estimator_test.exs`
Expected: all tests PASS

- [ ] **Step 5: Commit**

```
git add v3/apps/pi_core/lib/pi_core/token_estimator.ex v3/apps/pi_core/test/pi_core/token_estimator_test.exs
```
Message: `add TokenEstimator for byte_size/4 token estimation`

---

### Task 2: Truncate helper

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/truncate.ex`
- Create: `v3/apps/pi_core/test/pi_core/truncate_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# v3/apps/pi_core/test/pi_core/truncate_test.exs
defmodule PiCore.TruncateTest do
  use ExUnit.Case

  alias PiCore.Truncate

  test "returns text unchanged when under limit" do
    assert Truncate.head_tail("short text", 100) == "short text"
  end

  test "returns text unchanged when within 10% of limit" do
    text = String.duplicate("a", 95)
    assert Truncate.head_tail(text, 100) == text
  end

  test "truncates with head and tail when over limit" do
    text = String.duplicate("x", 1000)
    result = Truncate.head_tail(text, 200)
    assert byte_size(result) <= 200
    assert result =~ "[truncated"
    # Should start with x's and end with x's
    assert String.starts_with?(result, "x")
    assert String.ends_with?(result, "x")
  end

  test "snaps to newline boundaries" do
    lines = Enum.map(1..100, &"line #{&1}") |> Enum.join("\n")
    result = Truncate.head_tail(lines, 200)
    # Should not have a partial line
    assert result =~ "[truncated"
    parts = String.split(result, "\n")
    refute Enum.any?(parts, &String.starts_with?(&1, "e "))  # no mid-word splits
  end

  test "respects minimum max_chars of 200" do
    text = String.duplicate("a", 500)
    # Even with max_chars=50, should use 200 minimum
    result = Truncate.head_tail(text, 50)
    assert byte_size(result) <= 200
  end

  test "handles nil" do
    assert Truncate.head_tail(nil, 100) == ""
  end

  test "custom head/tail ratios" do
    text = String.duplicate("x", 1000)
    result = Truncate.head_tail(text, 200, 0.5, 0.4)
    assert byte_size(result) <= 200
    assert result =~ "[truncated"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/truncate_test.exs`
Expected: compilation error

- [ ] **Step 3: Write the implementation**

```elixir
# v3/apps/pi_core/lib/pi_core/truncate.ex
defmodule PiCore.Truncate do
  @moduledoc """
  Head+tail truncation that preserves beginnings and ends of text.
  Snaps to newline boundaries to avoid partial lines.
  """

  @min_max_chars 200

  def head_tail(text, max_chars, head_ratio \\ 0.7, tail_ratio \\ 0.2)
  def head_tail(nil, _max_chars, _head_ratio, _tail_ratio), do: ""
  def head_tail(text, max_chars, head_ratio, tail_ratio) when is_binary(text) do
    max_chars = max(max_chars, @min_max_chars)

    # Within 10% of cap — just include it
    if byte_size(text) <= max_chars * 1.1 do
      text
    else
      do_truncate(text, max_chars, head_ratio, tail_ratio)
    end
  end

  defp do_truncate(text, max_chars, head_ratio, tail_ratio) do
    marker = "\n\n... [truncated — original was #{byte_size(text)} bytes, showing first/last portions] ...\n\n"
    marker_size = byte_size(marker)
    available = max_chars - marker_size

    if available <= 0 do
      String.slice(text, 0, max_chars)
    else
      head_size = trunc(available * head_ratio)
      tail_size = trunc(available * tail_ratio)

      head = text |> String.slice(0, head_size) |> snap_to_newline_end()
      tail = text |> String.slice(-tail_size, tail_size) |> snap_to_newline_start()

      head <> marker <> tail
    end
  end

  defp snap_to_newline_end(text) do
    case String.split(text, "\n") do
      [single] -> single
      parts -> parts |> Enum.drop(-1) |> Enum.join("\n")
    end
  end

  defp snap_to_newline_start(text) do
    case String.split(text, "\n", parts: 2) do
      [_partial, rest] -> rest
      [single] -> single
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/truncate_test.exs`
Expected: all tests PASS

- [ ] **Step 5: Commit**

```
git add v3/apps/pi_core/lib/pi_core/truncate.ex v3/apps/pi_core/test/pi_core/truncate_test.exs
```
Message: `add Truncate helper with head+tail and newline snapping`

---

### Task 3: TokenBudget struct

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/token_budget.ex`
- Create: `v3/apps/pi_core/test/pi_core/token_budget_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# v3/apps/pi_core/test/pi_core/token_budget_test.exs
defmodule PiCore.TokenBudgetTest do
  use ExUnit.Case

  alias PiCore.TokenBudget

  test "compute/1 with defaults" do
    budget = TokenBudget.compute(128_000)
    assert budget.context_window == 128_000
    assert budget.system_prompt == 19_200   # 15%
    assert budget.tool_definitions == 6_400  # 5%
    assert budget.history == 64_000          # 50%
    assert budget.tool_results == 25_600     # 20%
    assert budget.response_reserve == 12_800 # 10%
  end

  test "compute/2 with custom ratios" do
    budget = TokenBudget.compute(100_000, %{
      system_prompt: 0.10,
      tool_definitions: 0.05,
      history: 0.55,
      tool_results: 0.20,
      response_reserve: 0.10
    })
    assert budget.system_prompt == 10_000
    assert budget.history == 55_000
  end

  test "compute/1 with small model" do
    budget = TokenBudget.compute(8_000)
    assert budget.system_prompt == 1_200
    assert budget.history == 4_000
    assert budget.tool_results == 1_600
  end

  test "per_tool_result_cap/1 is 30% of tool_results budget" do
    budget = TokenBudget.compute(128_000)
    assert TokenBudget.per_tool_result_cap(budget) == 7_680
  end

  test "summary_cap/1 is 15% of history budget" do
    budget = TokenBudget.compute(128_000)
    assert TokenBudget.summary_cap(budget) == 9_600
  end

  test "keep_recent_budget/1 is 30% of history budget" do
    budget = TokenBudget.compute(128_000)
    assert TokenBudget.keep_recent_budget(budget) == 19_200
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/token_budget_test.exs`

- [ ] **Step 3: Write the implementation**

```elixir
# v3/apps/pi_core/lib/pi_core/token_budget.ex
defmodule PiCore.TokenBudget do
  @moduledoc """
  Per-session token budget allocations, proportional to context window.
  """

  defstruct [:context_window, :system_prompt, :tool_definitions, :history,
             :tool_results, :response_reserve]

  @default_ratios %{
    system_prompt: 0.15,
    tool_definitions: 0.05,
    history: 0.50,
    tool_results: 0.20,
    response_reserve: 0.10
  }

  def compute(context_window, ratios \\ %{}) do
    r = Map.merge(@default_ratios, ratios)

    %__MODULE__{
      context_window: context_window,
      system_prompt: trunc(context_window * r.system_prompt),
      tool_definitions: trunc(context_window * r.tool_definitions),
      history: trunc(context_window * r.history),
      tool_results: trunc(context_window * r.tool_results),
      response_reserve: trunc(context_window * r.response_reserve)
    }
  end

  def per_tool_result_cap(%__MODULE__{tool_results: tr}), do: trunc(tr * 0.3)

  def summary_cap(%__MODULE__{history: h}), do: trunc(h * 0.15)

  def keep_recent_budget(%__MODULE__{history: h}), do: trunc(h * 0.3)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/token_budget_test.exs`

- [ ] **Step 5: Commit**

```
git add v3/apps/pi_core/lib/pi_core/token_budget.ex v3/apps/pi_core/test/pi_core/token_budget_test.exs
```
Message: `add TokenBudget struct with proportional allocation`

---

### Task 4: ModelInfo behaviour and DB migration

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/model_info.ex`
- Create: `v3/apps/druzhok/lib/druzhok/model_info.ex`
- Create: `v3/apps/druzhok/priv/repo/migrations/20260323000001_add_context_window_to_models.exs`
- Modify: `v3/apps/druzhok/lib/druzhok/model.ex`
- Create: `v3/apps/druzhok/test/druzhok/model_info_test.exs`

- [ ] **Step 1: Create the behaviour in pi_core**

```elixir
# v3/apps/pi_core/lib/pi_core/model_info.ex
defmodule PiCore.ModelInfo do
  @moduledoc """
  Behaviour for model metadata lookup.
  Implementations live outside pi_core (e.g. in druzhok app) to keep pi_core DB-free.
  """

  @callback context_window(model_name :: String.t()) :: pos_integer()
  @callback supports_reasoning?(model_name :: String.t()) :: boolean()
  @callback supports_tools?(model_name :: String.t()) :: boolean()

  @doc "Strip provider prefix from model ID: nebius/deepseek-ai/DeepSeek-R1 -> DeepSeek-R1"
  def strip_provider(model_id) do
    model_id
    |> String.split("/")
    |> List.last()
  end
end
```

- [ ] **Step 2: Create the migration**

```elixir
# v3/apps/druzhok/priv/repo/migrations/20260323000001_add_context_window_to_models.exs
defmodule Druzhok.Repo.Migrations.AddContextWindowToModels do
  use Ecto.Migration

  def change do
    alter table(:models) do
      add :context_window, :integer, default: 32_000
      add :supports_reasoning, :boolean, default: false
      add :supports_tools, :boolean, default: true
    end
  end
end
```

- [ ] **Step 3: Run migration**

Run: `cd v3 && mix ecto.migrate`
Expected: migration applied

- [ ] **Step 4: Update Model schema**

Add the new fields to `v3/apps/druzhok/lib/druzhok/model.ex`:

```elixir
# In the schema block, add after `field :position`:
field :context_window, :integer, default: 32_000
field :supports_reasoning, :boolean, default: false
field :supports_tools, :boolean, default: true
```

Update `changeset/2` to cast the new fields:
```elixir
|> cast(attrs, [:model_id, :label, :provider, :position, :context_window, :supports_reasoning, :supports_tools])
```

- [ ] **Step 5: Write failing test for Druzhok.ModelInfo**

```elixir
# v3/apps/druzhok/test/druzhok/model_info_test.exs
defmodule Druzhok.ModelInfoTest do
  use ExUnit.Case
  alias Druzhok.ModelInfo

  # These tests need the DB. If Druzhok.DataCase exists, use it.
  # Otherwise, ensure Repo is started in test_helper.exs.

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Druzhok.Repo)
    :ok
  end

  test "context_window returns default for unknown model" do
    assert ModelInfo.context_window("totally-unknown-model") == 32_000
  end

  test "context_window strips provider prefix" do
    assert ModelInfo.context_window("nebius/some/unknown") == 32_000
  end

  test "context_window returns DB value for known model" do
    Druzhok.Repo.insert!(%Druzhok.Model{
      model_id: "test-model", label: "Test", context_window: 128_000
    })
    assert ModelInfo.context_window("test-model") == 128_000
  end

  test "context_window matches after stripping provider prefix" do
    Druzhok.Repo.insert!(%Druzhok.Model{
      model_id: "DeepSeek-R1", label: "DS", context_window: 64_000, supports_reasoning: true
    })
    assert ModelInfo.context_window("nebius/deepseek-ai/DeepSeek-R1") == 64_000
  end

  test "supports_reasoning? returns false for unknown model" do
    refute ModelInfo.supports_reasoning?("unknown")
  end

  test "supports_tools? returns true for unknown model" do
    assert ModelInfo.supports_tools?("unknown")
  end
end
```

- [ ] **Step 6: Write the implementation**

```elixir
# v3/apps/druzhok/lib/druzhok/model_info.ex
defmodule Druzhok.ModelInfo do
  @behaviour PiCore.ModelInfo

  @default_context_window 32_000

  @impl true
  def context_window(model_name) do
    case lookup(model_name) do
      nil -> default_context_window()
      model -> model.context_window || default_context_window()
    end
  end

  @impl true
  def supports_reasoning?(model_name) do
    case lookup(model_name) do
      nil -> false
      model -> model.supports_reasoning || false
    end
  end

  @impl true
  def supports_tools?(model_name) do
    case lookup(model_name) do
      nil -> true
      model -> model.supports_tools
    end
  end

  defp lookup(model_name) do
    stripped = PiCore.ModelInfo.strip_provider(model_name)

    # Try exact match first, then stripped
    case Druzhok.Repo.get_by(Druzhok.Model, model_id: model_name) do
      nil -> Druzhok.Repo.get_by(Druzhok.Model, model_id: stripped)
      model -> model
    end
  end

  defp default_context_window do
    case Druzhok.Settings.get("default_context_window") do
      nil -> @default_context_window
      val -> String.to_integer(val)
    end
  end
end
```

- [ ] **Step 7: Run tests**

Run: `cd v3 && mix test apps/druzhok/test/druzhok/model_info_test.exs`
Expected: PASS

- [ ] **Step 8: Commit**

```
git add v3/apps/pi_core/lib/pi_core/model_info.ex v3/apps/druzhok/lib/druzhok/model_info.ex v3/apps/druzhok/lib/druzhok/model.ex v3/apps/druzhok/priv/repo/migrations/20260323000001_add_context_window_to_models.exs v3/apps/druzhok/test/druzhok/model_info_test.exs
```
Message: `add ModelInfo behaviour and DB-backed implementation`

---

### Task 5: Message transform — reasoning stripping + tool result compaction

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/transform.ex`
- Create: `v3/apps/pi_core/test/pi_core/transform_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# v3/apps/pi_core/test/pi_core/transform_test.exs
defmodule PiCore.TransformTest do
  use ExUnit.Case

  alias PiCore.Transform
  alias PiCore.Loop.Message
  alias PiCore.TokenBudget

  @budget TokenBudget.compute(32_000)

  describe "strip_reasoning/1" do
    test "removes reasoning from old assistant messages" do
      messages = [
        %Message{role: "assistant", content: "answer 1", tool_calls: nil,
                 metadata: %{reasoning: "long thinking process here..."}},
        %Message{role: "user", content: "follow up"},
        %Message{role: "assistant", content: "answer 2",
                 metadata: %{reasoning: "more thinking"}}
      ]

      result = Transform.strip_reasoning(messages)
      # All but the last assistant should have reasoning stripped
      first = Enum.at(result, 0)
      last = Enum.at(result, 2)
      assert first.metadata[:reasoning] == nil
      # Last assistant keeps reasoning (it's the current response context)
      assert last.metadata[:reasoning] == "more thinking"
    end

    test "handles messages without reasoning" do
      messages = [
        %Message{role: "user", content: "hello"},
        %Message{role: "assistant", content: "hi"}
      ]
      assert Transform.strip_reasoning(messages) == messages
    end
  end

  describe "compact_tool_results/2" do
    test "compacts old tool results when over budget" do
      big_result = String.duplicate("x", 10_000)
      messages = [
        %Message{role: "toolResult", content: big_result, tool_call_id: "1", tool_name: "bash"},
        %Message{role: "assistant", content: "done"},
        %Message{role: "user", content: "more"},
        %Message{role: "toolResult", content: big_result, tool_call_id: "2", tool_name: "read"},
        %Message{role: "assistant", content: "ok"}
      ]

      # With a small budget, old results should be compacted
      small_budget = TokenBudget.compute(8_000)
      result = Transform.compact_tool_results(messages, small_budget, 4)
      first_tool = Enum.at(result, 0)
      assert first_tool.content =~ "[Tool output compacted"
    end

    test "never compacts results from current iteration" do
      big_result = String.duplicate("x", 10_000)
      messages = [
        %Message{role: "toolResult", content: big_result, tool_call_id: "1", tool_name: "bash"},
      ]

      small_budget = TokenBudget.compute(8_000)
      # current_iteration_start = 0 means all messages are from current iteration
      result = Transform.compact_tool_results(messages, small_budget, 0)
      assert Enum.at(result, 0).content == big_result
    end

    test "leaves results alone when under budget" do
      messages = [
        %Message{role: "toolResult", content: "small output", tool_call_id: "1", tool_name: "bash"},
      ]
      result = Transform.compact_tool_results(messages, @budget, 0)
      assert result == messages
    end
  end

  describe "transform_messages/3" do
    test "applies both reasoning stripping and tool compaction" do
      messages = [
        %Message{role: "assistant", content: "x", metadata: %{reasoning: "think"}},
        %Message{role: "toolResult", content: String.duplicate("y", 10_000),
                 tool_call_id: "1", tool_name: "bash"},
        %Message{role: "user", content: "ok"},
        %Message{role: "assistant", content: "done"}
      ]

      small_budget = TokenBudget.compute(8_000)
      result = Transform.transform_messages(messages, small_budget, 3)
      first = Enum.at(result, 0)
      assert first.metadata[:reasoning] == nil
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/transform_test.exs`

- [ ] **Step 3: Add metadata field to Loop.Message**

In `v3/apps/pi_core/lib/pi_core/loop.ex`, update the Message struct:

```elixir
defstruct [:role, :content, :tool_calls, :tool_call_id, :tool_name, :is_error, :timestamp, metadata: %{}]
```

- [ ] **Step 4: Write the implementation**

```elixir
# v3/apps/pi_core/lib/pi_core/transform.ex
defmodule PiCore.Transform do
  @moduledoc """
  Message transforms applied before LLM calls.
  Operates on copies — canonical messages stay intact.
  """

  alias PiCore.Loop.Message
  alias PiCore.TokenEstimator
  alias PiCore.TokenBudget

  @doc "Strip reasoning from all assistant messages except the last one."
  def strip_reasoning(messages) do
    last_assistant_idx = messages
    |> Enum.with_index()
    |> Enum.filter(fn {m, _} -> m.role == "assistant" end)
    |> List.last()
    |> case do
      nil -> -1
      {_, idx} -> idx
    end

    Enum.with_index(messages, fn msg, idx ->
      if msg.role == "assistant" and idx != last_assistant_idx and is_map(msg.metadata) and msg.metadata[:reasoning] do
        %{msg | metadata: Map.delete(msg.metadata, :reasoning)}
      else
        msg
      end
    end)
  end

  @doc """
  Compact old tool results when total exceeds budget.
  Never compacts results at or after current_iteration_start index.
  """
  def compact_tool_results(messages, %TokenBudget{} = budget, current_iteration_start) do
    total = messages
    |> Enum.filter(&(&1.role == "toolResult"))
    |> Enum.reduce(0, fn m, acc -> acc + TokenEstimator.estimate(m.content) end)

    if total <= budget.tool_results do
      messages
    else
      do_compact_tool_results(messages, budget.tool_results, current_iteration_start)
    end
  end

  defp do_compact_tool_results(messages, budget, current_start) do
    {result, _} = Enum.reduce(Enum.with_index(messages), {[], 0}, fn {msg, idx}, {acc, running} ->
      if msg.role == "toolResult" and idx < current_start and running > budget do
        original_size = byte_size(msg.content || "")
        compacted = %{msg | content: "[Tool output compacted — #{original_size} bytes removed]"}
        {acc ++ [compacted], running - TokenEstimator.estimate(msg.content) + TokenEstimator.estimate(compacted.content)}
      else
        new_running = if msg.role == "toolResult", do: running + TokenEstimator.estimate(msg.content), else: running
        {acc ++ [msg], new_running}
      end
    end)
    result
  end

  @doc "Apply all transforms: reasoning strip then tool result compaction."
  def transform_messages(messages, %TokenBudget{} = budget, current_iteration_start) do
    messages
    |> strip_reasoning()
    |> compact_tool_results(budget, current_iteration_start)
  end
end
```

- [ ] **Step 5: Run tests**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/transform_test.exs`
Expected: PASS

- [ ] **Step 6: Commit**

```
git add v3/apps/pi_core/lib/pi_core/transform.ex v3/apps/pi_core/test/pi_core/transform_test.exs v3/apps/pi_core/lib/pi_core/loop.ex
```
Message: `add Transform for reasoning stripping and tool result compaction`

---

### Task 6: PromptBudget — budget-aware system prompt builder

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/prompt_budget.ex`
- Create: `v3/apps/pi_core/test/pi_core/prompt_budget_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# v3/apps/pi_core/test/pi_core/prompt_budget_test.exs
defmodule PiCore.PromptBudgetTest do
  use ExUnit.Case

  alias PiCore.PromptBudget

  @workspace System.tmp_dir!() |> Path.join("prompt_budget_test_#{:rand.uniform(99999)}")

  setup do
    File.mkdir_p!(@workspace)

    File.write!(Path.join(@workspace, "IDENTITY.md"), "I am TestBot.")
    File.write!(Path.join(@workspace, "SOUL.md"), "Be helpful and kind.")
    File.write!(Path.join(@workspace, "AGENTS.md"), "Follow these rules:\n1. Be concise\n2. Use tools")
    File.write!(Path.join(@workspace, "USER.md"), "User prefers English.")

    on_exit(fn -> File.rm_rf!(@workspace) end)
    :ok
  end

  test "builds prompt from workspace files" do
    {prompt, tokens} = PromptBudget.build(@workspace, %{budget_tokens: 5_000})
    assert prompt =~ "TestBot"
    assert prompt =~ "helpful and kind"
    assert prompt =~ "Follow these rules"
    assert tokens > 0
  end

  test "excludes USER.md in group mode" do
    {prompt, _} = PromptBudget.build(@workspace, %{budget_tokens: 5_000, group: true})
    refute prompt =~ "prefers English"
  end

  test "truncates large files with head+tail" do
    big_content = String.duplicate("Important rule number one.\n", 500)
    File.write!(Path.join(@workspace, "AGENTS.md"), big_content)

    # Very small budget forces truncation
    {prompt, _} = PromptBudget.build(@workspace, %{budget_tokens: 200})
    assert prompt =~ "[truncated"
  end

  test "formats skills catalog with tiered fallback" do
    skills = [
      {"greeting", "Greet the user warmly", "./skills/greeting/SKILL.md"},
      {"coding", "Help with coding tasks", "./skills/coding/SKILL.md"},
    ]

    {prompt, _} = PromptBudget.build(@workspace, %{budget_tokens: 5_000, skills: skills})
    assert prompt =~ "greeting"
    assert prompt =~ "coding"
  end

  test "compresses skills to compact format when budget is tight" do
    skills = for i <- 1..50 do
      {"skill_#{i}", String.duplicate("description ", 20), "./skills/skill_#{i}/SKILL.md"}
    end

    {prompt, _} = PromptBudget.build(@workspace, %{budget_tokens: 500, skills: skills})
    # Should have skill names but maybe not full descriptions
    assert prompt =~ "skill_1"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/prompt_budget_test.exs`

- [ ] **Step 3: Write the implementation**

```elixir
# v3/apps/pi_core/lib/pi_core/prompt_budget.ex
defmodule PiCore.PromptBudget do
  @moduledoc """
  Budget-aware system prompt construction.
  Allocates space to identity, instructions, and skills within a token budget.
  """

  alias PiCore.TokenEstimator
  alias PiCore.Truncate

  @identity_files ["IDENTITY.md", "SOUL.md"]
  @instruction_files ["AGENTS.md", "USER.md", "BOOTSTRAP.md"]

  def build(workspace, opts) do
    budget_tokens = opts[:budget_tokens] || 5_000
    budget_chars = budget_tokens * 4  # inverse of byte_size/4
    group = opts[:group] || false
    skills = opts[:skills] || []
    read_fn = opts[:read_fn] || &File.read/1

    # Phase 1: Identity (highest priority — up to 20% of budget)
    identity_budget = trunc(budget_chars * 0.20)
    identity = load_files(workspace, @identity_files, identity_budget, read_fn)

    remaining = budget_chars - byte_size(identity)

    # Phase 2: Instructions (up to 40% of budget per file)
    instruction_files = if group, do: @instruction_files -- ["USER.md"], else: @instruction_files
    per_file_cap = trunc(budget_chars * 0.40)
    instructions = load_files(workspace, instruction_files, per_file_cap, read_fn)

    remaining = remaining - byte_size(instructions)

    # Phase 3: Skills catalog (remaining space)
    skills_section = if skills != [] and remaining > 100 do
      format_skills(skills, remaining)
    else
      ""
    end

    prompt = [identity, instructions, skills_section]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")

    tokens = TokenEstimator.estimate(prompt)
    {prompt, tokens}
  end

  defp load_files(workspace, files, per_file_cap, read_fn) do
    files
    |> Enum.map(fn file ->
      path = if read_fn == (&File.read/1), do: Path.join(workspace, file), else: file
      case read_fn.(path) do
        {:ok, content} -> Truncate.head_tail(content, per_file_cap)
        {:error, _} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp format_skills(skills, remaining_chars) do
    full = format_skills_full(skills)
    if byte_size(full) <= remaining_chars do
      return_skills(full)
    else
      compact = format_skills_compact(skills)
      if byte_size(compact) <= remaining_chars do
        return_skills(compact)
      else
        minimal = format_skills_minimal(skills)
        if byte_size(minimal) <= remaining_chars do
          return_skills(minimal)
        else
          Truncate.head_tail(return_skills(minimal), remaining_chars)
        end
      end
    end
  end

  defp return_skills(body) do
    "## Available Skills\n\n#{body}"
  end

  defp format_skills_full(skills) do
    Enum.map_join(skills, "\n", fn {name, desc, path} ->
      "- **#{name}**: #{desc} (`#{path}`)"
    end)
  end

  defp format_skills_compact(skills) do
    Enum.map_join(skills, "\n", fn {name, _desc, path} ->
      "- #{name} (`#{path}`)"
    end)
  end

  defp format_skills_minimal(skills) do
    Enum.map_join(skills, "\n", fn {name, _desc, _path} ->
      "- #{name}"
    end)
  end
end
```

- [ ] **Step 4: Run tests**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/prompt_budget_test.exs`

- [ ] **Step 5: Commit**

```
git add v3/apps/pi_core/lib/pi_core/prompt_budget.ex v3/apps/pi_core/test/pi_core/prompt_budget_test.exs
```
Message: `add PromptBudget with tiered skill formatting`

---

### Task 7: Rewrite Compaction to be token-based with iterative summarization

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/compaction.ex`
- Modify: `v3/apps/pi_core/test/pi_core/compaction_test.exs`

- [ ] **Step 1: Write the new failing tests**

```elixir
# Replace v3/apps/pi_core/test/pi_core/compaction_test.exs
defmodule PiCore.CompactionTest do
  use ExUnit.Case

  alias PiCore.Compaction
  alias PiCore.Loop.Message
  alias PiCore.TokenBudget

  @budget TokenBudget.compute(8_000)  # small model for easier testing

  defp make_messages(count, content_size \\ 50) do
    for i <- 1..count do
      %Message{
        role: if(rem(i, 2) == 1, do: "user", else: "assistant"),
        content: String.duplicate("x", content_size) <> " #{i}",
        timestamp: i
      }
    end
  end

  defp mock_llm do
    fn _opts -> {:ok, %PiCore.LLM.Client.Result{content: "Summary of conversation", tool_calls: []}} end
  end

  test "no compaction when under token budget" do
    messages = make_messages(5)
    {result, compacted?} = Compaction.maybe_compact(messages, %{budget: @budget, llm_fn: mock_llm()})
    assert result == messages
    refute compacted?
  end

  test "compacts when over token budget" do
    # Many large messages to exceed 8K model budget
    messages = make_messages(30, 200)
    {result, compacted?} = Compaction.maybe_compact(messages, %{budget: @budget, llm_fn: mock_llm()})
    assert compacted?
    assert length(result) < length(messages)
  end

  test "summary message has compaction_summary metadata" do
    messages = make_messages(30, 200)
    {result, true} = Compaction.maybe_compact(messages, %{budget: @budget, llm_fn: mock_llm()})
    summary = hd(result)
    assert summary.metadata[:type] == :compaction_summary
    assert summary.metadata[:version] == 1
  end

  test "iterative compaction increments version" do
    # First summary
    summary = %Message{
      role: "user",
      content: "[System: Compaction summary v1]\nPrevious summary here.",
      metadata: %{type: :compaction_summary, version: 1},
      timestamp: 0
    }
    rest = make_messages(30, 200)
    messages = [summary | rest]

    {result, true} = Compaction.maybe_compact(messages, %{budget: @budget, llm_fn: mock_llm()})
    new_summary = hd(result)
    assert new_summary.metadata[:version] == 2
  end

  test "keeps recent messages as complete turns" do
    # Create a tool call sequence that should stay together
    messages = [
      %Message{role: "user", content: String.duplicate("a", 200), timestamp: 1},
      %Message{role: "assistant", content: "", tool_calls: [%{"id" => "1", "function" => %{"name" => "bash", "arguments" => "{}"}}], timestamp: 2},
      %Message{role: "toolResult", content: "output", tool_call_id: "1", tool_name: "bash", timestamp: 3},
      %Message{role: "assistant", content: "done", timestamp: 4}
    ] ++ make_messages(30, 200)

    {result, true} = Compaction.maybe_compact(messages, %{budget: @budget, llm_fn: mock_llm()})
    # Recent messages should be present and turns intact
    roles = Enum.map(result, & &1.role)
    # If there's a toolResult, its associated assistant+tool_call should also be there
    if "toolResult" in roles do
      tr_idx = Enum.find_index(result, &(&1.role == "toolResult"))
      assert tr_idx > 0
      prev = Enum.at(result, tr_idx - 1)
      assert prev.role == "assistant"
      assert prev.tool_calls != nil
    end
  end

  test "fallback when llm_fn is nil" do
    messages = make_messages(30, 200)
    {result, compacted?} = Compaction.maybe_compact(messages, %{budget: @budget})
    assert compacted?
    summary = hd(result)
    assert summary.content =~ "compacted"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/compaction_test.exs`

- [ ] **Step 3: Rewrite the Compaction module**

```elixir
# v3/apps/pi_core/lib/pi_core/compaction.ex
defmodule PiCore.Compaction do
  @moduledoc """
  Token-based context window compaction with iterative summarization.
  """

  alias PiCore.Loop.Message
  alias PiCore.TokenEstimator
  alias PiCore.TokenBudget
  alias PiCore.Truncate

  def maybe_compact(messages, opts) do
    case opts[:budget] do
      %TokenBudget{} = budget ->
        total_tokens = TokenEstimator.estimate_messages(messages)
        if total_tokens <= budget.history do
          {messages, false}
        else
          compact(messages, budget, opts[:llm_fn])
        end

      nil ->
        # Legacy fallback: message-count based (backward compatible)
        max = opts[:max_messages] || 40
        keep = opts[:keep_recent] || 10
        if length(messages) <= max do
          {messages, false}
        else
          legacy_compact(messages, keep, opts[:llm_fn])
        end
    end
  end

  defp compact(messages, budget, llm_fn) do
    keep_budget = TokenBudget.keep_recent_budget(budget)
    {old, recent} = split_keeping_turns(messages, keep_budget)

    {existing_summary, old_without_summary} = extract_existing_summary(old)
    version = if existing_summary, do: existing_summary.metadata[:version] + 1, else: 1

    summary_text = if llm_fn do
      generate_summary(old_without_summary, existing_summary, llm_fn)
    else
      fallback_summary(old_without_summary)
    end

    summary_cap_chars = TokenBudget.summary_cap(budget) * 4
    summary_text = Truncate.head_tail(summary_text, summary_cap_chars)

    summary_msg = %Message{
      role: "user",
      content: "[System: Compaction summary v#{version}]\n#{summary_text}",
      metadata: %{type: :compaction_summary, version: version},
      timestamp: System.os_time(:millisecond)
    }

    {[summary_msg | recent], true}
  end

  defp split_keeping_turns(messages, keep_budget) do
    # Walk backwards, accumulating tokens, never splitting tool-call/result sequences
    {recent_reversed, _tokens} =
      messages
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn msg, {acc, tokens} ->
        msg_tokens = TokenEstimator.estimate_message(msg)
        new_total = tokens + msg_tokens

        if new_total > keep_budget and acc != [] and not in_tool_sequence?(msg, acc) do
          {:halt, {acc, tokens}}
        else
          {:cont, {[msg | acc], new_total}}
        end
      end)

    recent = recent_reversed
    split_idx = length(messages) - length(recent)
    old = Enum.take(messages, split_idx)
    {old, recent}
  end

  defp in_tool_sequence?(msg, following) do
    # Don't split if this is an assistant with tool_calls and next is toolResult
    # Or if this is a toolResult and previous in acc is assistant with tool_calls
    case msg.role do
      "assistant" ->
        msg.tool_calls != nil and msg.tool_calls != [] and
          match?([%{role: "toolResult"} | _], following)
      "toolResult" ->
        match?([%{role: "assistant"} | _], following)
      _ -> false
    end
  end

  defp extract_existing_summary(messages) do
    case Enum.find_index(messages, fn m ->
      is_map(m.metadata) and m.metadata[:type] == :compaction_summary
    end) do
      nil -> {nil, messages}
      idx ->
        summary = Enum.at(messages, idx)
        rest = List.delete_at(messages, idx)
        {summary, rest}
    end
  end

  defp generate_summary(messages, nil, llm_fn) do
    conversation = serialize_messages(messages)

    prompt = """
    Summarize the following conversation concisely. Use this structure:

    ## Goal
    ## Progress
    ## Key Decisions
    ## Files Read/Modified
    ## Next Steps

    Preserve UUIDs, file paths, API keys, URLs, and exact identifiers.

    <conversation>
    #{conversation}
    </conversation>
    """

    call_llm(prompt, llm_fn)
  end

  defp generate_summary(messages, existing_summary, llm_fn) do
    new_messages = serialize_messages(messages)

    prompt = """
    Update this conversation summary with the new messages below.
    Merge new information into the existing structure. Do not repeat what is already captured.

    <existing-summary>
    #{existing_summary.content}
    </existing-summary>

    <new-messages>
    #{new_messages}
    </new-messages>
    """

    call_llm(prompt, llm_fn)
  end

  defp call_llm(prompt, llm_fn) do
    case llm_fn.(%{
      system_prompt: "You are a conversation summarizer. Be concise and factual.",
      messages: [%{role: "user", content: prompt}],
      tools: [],
      on_delta: nil
    }) do
      {:ok, result} -> result.content
      {:error, _} -> "Previous conversation context (summarization failed)"
    end
  end

  defp serialize_messages(messages) do
    messages
    |> Enum.map(fn msg ->
      role = msg.role
      content = msg.content
      tool_info = if msg.tool_name, do: " [#{msg.tool_name}]", else: ""
      if content, do: "[#{role}#{tool_info}]: #{String.slice(content, 0, 2000)}", else: nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp fallback_summary(messages) do
    messages
    |> Enum.filter(&(&1.role == "assistant"))
    |> Enum.map(& &1.content)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> then(&"[Previous conversation was compacted: #{&1}]")
  end

  # Legacy message-count based compaction for backward compatibility
  defp legacy_compact(messages, keep_recent, llm_fn) do
    split_point = length(messages) - keep_recent
    {old_messages, recent_messages} = Enum.split(messages, split_point)

    summary = if llm_fn do
      call_llm(serialize_messages(old_messages), llm_fn)
    else
      fallback_summary(old_messages)
    end

    summary_msg = %Message{
      role: "user",
      content: "[System: Previous conversation was compacted. Summary:\n#{summary}]",
      metadata: %{type: :compaction_summary, version: 1},
      timestamp: System.os_time(:millisecond)
    }

    {[summary_msg | recent_messages], true}
  end
end
```

- [ ] **Step 4: Run tests**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/compaction_test.exs`

- [ ] **Step 5: Run existing tests to check for regressions**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/session_test.exs`

Note: Session tests that use Compaction will need their opts updated to pass `budget` instead of `max_messages`. Fix any failures by updating the Session module (next task).

- [ ] **Step 6: Commit**

```
git add v3/apps/pi_core/lib/pi_core/compaction.ex v3/apps/pi_core/test/pi_core/compaction_test.exs
```
Message: `rewrite Compaction to token-based with iterative summarization`

---

### Task 8: Wire budget into Session and Loop

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/session.ex`
- Modify: `v3/apps/pi_core/lib/pi_core/loop.ex`
- Modify: `v3/apps/pi_core/lib/pi_core/session_store.ex`
- Modify: `v3/apps/druzhok/lib/druzhok/instance/sup.ex`

- [ ] **Step 1: Update Session to compute and store budget**

In `v3/apps/pi_core/lib/pi_core/session.ex`:

Add to struct: `:budget, :model_info_fn`

Update `init/1`:
```elixir
def init(opts) do
  # ... existing workspace loading ...
  model_info_fn = opts[:model_info_fn]
  context_window = if model_info_fn, do: model_info_fn.(:context_window, opts.model), else: 32_000
  budget = PiCore.TokenBudget.compute(context_window, budget_ratios(opts))

  # Use PromptBudget instead of raw workspace loading
  {system_prompt, _tokens} = PiCore.PromptBudget.build(
    opts.workspace,
    %{budget_tokens: budget.system_prompt, group: group, read_fn: read_fn, skills: opts[:skills] || []}
  )
  system_prompt = append_model_info(system_prompt, opts.model)

  state = %__MODULE__{
    # ... existing fields ...
    budget: budget,
    model_info_fn: model_info_fn,
  }
  # ...
end
```

Update `handle_cast({:set_model, ...})` to recompute budget:
```elixir
def handle_cast({:set_model, model, opts}, state) do
  context_window = if state.model_info_fn, do: state.model_info_fn.(:context_window, model), else: 32_000
  budget = PiCore.TokenBudget.compute(context_window)

  {base_prompt, _} = PiCore.PromptBudget.build(state.workspace, %{
    budget_tokens: budget.system_prompt, group: state.group
  })
  system_prompt = append_model_info(base_prompt, model)

  state = %{state | model: model, system_prompt: system_prompt, budget: budget}
  state = if opts[:provider], do: %{state | provider: opts[:provider]}, else: state
  state = if opts[:api_url], do: %{state | api_url: opts[:api_url]}, else: state
  state = if opts[:api_key], do: %{state | api_key: opts[:api_key]}, else: state

  # Immediate compaction check with new budget
  {compacted, _} = PiCore.Compaction.maybe_compact(state.messages, %{
    budget: budget, llm_fn: state.llm_fn || &default_llm_fn(state, &1)
  })
  {:noreply, %{state | messages: compacted}}
end
```

Add `budget_ratios/1` helper to read from DB-stored settings:
```elixir
defp budget_ratios(_opts) do
  # Read from Druzhok.Settings via a callback, or use defaults
  %{
    system_prompt: parse_float_setting("system_prompt_budget_ratio", 0.15),
    tool_definitions: parse_float_setting("tool_definitions_budget_ratio", 0.05),
    history: parse_float_setting("history_budget_ratio", 0.50),
    tool_results: parse_float_setting("tool_result_budget_ratio", 0.20),
    response_reserve: parse_float_setting("response_reserve_ratio", 0.10)
  }
end

defp parse_float_setting(key, default) do
  case Application.get_env(:pi_core, String.to_atom(key)) do
    nil -> default
    val when is_float(val) -> val
    val when is_binary(val) -> String.to_float(val)
  end
end
```

Note: The `druzhok` app should set these in application env on startup from DB settings, keeping `pi_core` DB-free.

Update `run_prompt/2` to pass budget and call sanitize:
```elixir
defp run_prompt(messages, state) do
  llm_fn = state.llm_fn || &default_llm_fn(state, &1)

  {compacted_messages, _} = Compaction.maybe_compact(messages, %{
    budget: state.budget,
    llm_fn: llm_fn
  })

  # Pre-persistence guard: sanitize before saving
  sanitized = PiCore.SessionStore.sanitize_for_persistence(compacted_messages, state.budget)
  PiCore.SessionStore.save(state.workspace, sanitized)

  Loop.run(%{
    # ... existing fields ...
    budget: state.budget,
  })
end
```

- [ ] **Step 2: Update Loop to use transforms and budget-aware truncation**

In `v3/apps/pi_core/lib/pi_core/loop.ex`:

In `loop/6`, before building `llm_messages`, add transform and safety net:
```elixir
# After: all_messages = opts.messages ++ new_messages
transformed = if opts[:budget] do
  all_messages
  |> PiCore.Transform.transform_messages(opts.budget, length(opts.messages))
  |> safety_net(opts[:budget])
else
  all_messages
end

# Then use `transformed` instead of `all_messages` for llm_messages:
llm_messages = Enum.map(transformed, fn ...
```

Add the safety net function at the bottom of the module:
```elixir
defp safety_net(messages, %PiCore.TokenBudget{} = budget) do
  total = PiCore.TokenEstimator.estimate_messages(messages)
  max_allowed = budget.context_window - budget.response_reserve

  if total <= max_allowed do
    messages
  else
    require Logger
    Logger.warning("Safety net triggered: #{total} tokens exceeds #{max_allowed} limit, dropping oldest messages")
    drop_oldest_until_fits(messages, max_allowed)
  end
end
defp safety_net(messages, _), do: messages

defp drop_oldest_until_fits(messages, max) do
  # Never drop compaction summaries or the most recent 2 messages
  {droppable, protected} = Enum.split(messages, max(0, length(messages) - 2))
  droppable
  |> Enum.reject(fn m -> is_map(m.metadata) and m.metadata[:type] == :compaction_summary end)
  |> Enum.reverse()
  |> Enum.reduce_while(droppable, fn msg, remaining ->
    total = PiCore.TokenEstimator.estimate_messages(remaining ++ protected)
    if total <= max, do: {:halt, remaining}, else: {:cont, List.delete(remaining, msg)}
  end)
  |> Kernel.++(protected)
end
```

Update `truncate_output/1` to accept budget:
```elixir
defp truncate_output(text, opts) do
  max = if opts[:budget] do
    PiCore.TokenBudget.per_tool_result_cap(opts.budget) * 4  # tokens to chars
  else
    PiCore.Config.max_tool_output()
  end

  if byte_size(text) <= max do
    text
  else
    PiCore.Truncate.head_tail(text, max)
  end
end
```

Pass `opts` to `execute_tool_calls`:
```elixir
tool_results = execute_tool_calls(result.tool_calls, tools, tool_context, opts)
```

- [ ] **Step 3: Update SessionStore with pre-persistence guard**

In `v3/apps/pi_core/lib/pi_core/session_store.ex`, add:

```elixir
def sanitize_for_persistence(messages, budget) when is_struct(budget) do
  max_chars = PiCore.TokenBudget.per_tool_result_cap(budget) * 4 * 2  # 2x cap
  Enum.map(messages, fn msg ->
    if msg.role == "toolResult" and is_binary(msg.content) and byte_size(msg.content) > max_chars do
      %{msg | content: PiCore.Truncate.head_tail(msg.content, max_chars)}
    else
      msg
    end
  end)
end
def sanitize_for_persistence(messages, _), do: messages
```

- [ ] **Step 4: Inject model_info_fn in Instance.Sup**

In `v3/apps/druzhok/lib/druzhok/instance/sup.ex`, add to persistent_term config:

```elixir
model_info_fn: fn action, model_name ->
  case action do
    :context_window -> Druzhok.ModelInfo.context_window(model_name)
    :supports_reasoning -> Druzhok.ModelInfo.supports_reasoning?(model_name)
    :supports_tools -> Druzhok.ModelInfo.supports_tools?(model_name)
  end
end,
```

- [ ] **Step 5: Run full test suite**

Run: `cd v3 && mix test`
Expected: all tests PASS (fix any failures from the interface changes)

- [ ] **Step 6: Commit**

```
git add v3/apps/pi_core/lib/pi_core/session.ex v3/apps/pi_core/lib/pi_core/loop.ex v3/apps/pi_core/lib/pi_core/session_store.ex v3/apps/druzhok/lib/druzhok/instance/sup.ex
```
Message: `wire TokenBudget into Session, Loop, and SessionStore`

---

### Task 9: Dashboard — Model profiles CRUD page

**Files:**
- Create: `v3/apps/druzhok_web/lib/druzhok_web_web/live/models_live.ex`
- Modify: `v3/apps/druzhok_web/lib/druzhok_web_web/router.ex`

- [ ] **Step 1: Add route**

In `v3/apps/druzhok_web/lib/druzhok_web_web/router.ex`, in the authenticated scope add:

```elixir
live "/models", ModelsLive
```

- [ ] **Step 2: Create ModelsLive**

```elixir
# v3/apps/druzhok_web/lib/druzhok_web_web/live/models_live.ex
defmodule DruzhokWebWeb.ModelsLive do
  use DruzhokWebWeb, :live_view

  alias Druzhok.Model
  alias Druzhok.Repo
  import Ecto.Query

  @impl true
  def mount(_params, session, socket) do
    current_user = case session["user_id"] do
      nil -> nil
      id -> Repo.get(Druzhok.User, id)
    end

    unless current_user && current_user.role == "admin" do
      {:ok, redirect(socket, to: "/")}
    else
      models = from(m in Model, order_by: m.position) |> Repo.all()
      {:ok, assign(socket, current_user: current_user, models: models, editing: nil, saved: false)}
    end
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    model = Repo.get!(Model, id)
    {:noreply, assign(socket, editing: model, saved: false)}
  end

  @impl true
  def handle_event("cancel", _, socket) do
    {:noreply, assign(socket, editing: nil)}
  end

  @impl true
  def handle_event("save", params, socket) do
    model = if socket.assigns.editing, do: socket.assigns.editing, else: %Model{}
    attrs = %{
      model_id: params["model_id"],
      label: params["label"],
      provider: params["provider"] || "openai",
      context_window: parse_int(params["context_window"], 32_000),
      supports_reasoning: params["supports_reasoning"] == "true",
      supports_tools: params["supports_tools"] != "false",
      position: parse_int(params["position"], 0)
    }

    case Model.changeset(model, attrs) |> Repo.insert_or_update() do
      {:ok, _} ->
        models = from(m in Model, order_by: m.position) |> Repo.all()
        Phoenix.PubSub.broadcast(DruzhokWeb.PubSub, "settings", {:models_updated})
        {:noreply, assign(socket, models: models, editing: nil, saved: true)}
      {:error, _cs} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    Repo.get!(Model, id) |> Repo.delete!()
    models = from(m in Model, order_by: m.position) |> Repo.all()
    Phoenix.PubSub.broadcast(DruzhokWeb.PubSub, "settings", {:models_updated})
    {:noreply, assign(socket, models: models, saved: false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50">
      <div class="max-w-4xl mx-auto p-6">
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-xl font-bold">Model Profiles</h1>
          <a href="/" class="text-sm text-gray-500 hover:text-gray-900">&larr; Dashboard</a>
        </div>

        <div class="bg-white rounded-xl border border-gray-200 overflow-hidden">
          <table class="w-full text-sm">
            <thead class="bg-gray-50 border-b">
              <tr>
                <th class="px-4 py-2 text-left font-medium text-gray-500">Model ID</th>
                <th class="px-4 py-2 text-left font-medium text-gray-500">Label</th>
                <th class="px-4 py-2 text-left font-medium text-gray-500">Provider</th>
                <th class="px-4 py-2 text-right font-medium text-gray-500">Context</th>
                <th class="px-4 py-2 text-center font-medium text-gray-500">Reasoning</th>
                <th class="px-4 py-2 text-center font-medium text-gray-500">Tools</th>
                <th class="px-4 py-2"></th>
              </tr>
            </thead>
            <tbody>
              <tr :for={model <- @models} class="border-b last:border-b-0 hover:bg-gray-50">
                <td class="px-4 py-2 font-mono text-xs"><%= model.model_id %></td>
                <td class="px-4 py-2"><%= model.label %></td>
                <td class="px-4 py-2 text-gray-500"><%= model.provider %></td>
                <td class="px-4 py-2 text-right font-mono"><%= format_number(model.context_window || 32_000) %></td>
                <td class="px-4 py-2 text-center"><%= if model.supports_reasoning, do: "Yes", else: "-" %></td>
                <td class="px-4 py-2 text-center"><%= if model.supports_tools, do: "Yes", else: "-" %></td>
                <td class="px-4 py-2 text-right space-x-2">
                  <button phx-click="edit" phx-value-id={model.id} class="text-xs text-blue-600 hover:underline">Edit</button>
                  <button phx-click="delete" phx-value-id={model.id}
                          data-confirm="Delete this model?" class="text-xs text-red-600 hover:underline">Delete</button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="mt-6 bg-white rounded-xl border border-gray-200 p-6">
          <h2 class="text-sm font-semibold mb-4">
            <%= if @editing, do: "Edit Model", else: "Add Model" %>
          </h2>
          <form phx-submit="save" class="grid grid-cols-2 gap-4">
            <div>
              <label class="block text-xs text-gray-500 mb-1">Model ID</label>
              <input name="model_id" value={if @editing, do: @editing.model_id, else: ""}
                     required class="w-full border rounded-lg px-3 py-2 text-sm font-mono" />
            </div>
            <div>
              <label class="block text-xs text-gray-500 mb-1">Label</label>
              <input name="label" value={if @editing, do: @editing.label, else: ""}
                     required class="w-full border rounded-lg px-3 py-2 text-sm" />
            </div>
            <div>
              <label class="block text-xs text-gray-500 mb-1">Provider</label>
              <select name="provider" class="w-full border rounded-lg px-3 py-2 text-sm">
                <option value="openai" selected={if @editing, do: @editing.provider == "openai"}>OpenAI-compatible</option>
                <option value="anthropic" selected={if @editing, do: @editing.provider == "anthropic"}>Anthropic</option>
              </select>
            </div>
            <div>
              <label class="block text-xs text-gray-500 mb-1">Context Window (tokens)</label>
              <input name="context_window" type="number" value={if @editing, do: @editing.context_window || 32_000, else: 32_000}
                     class="w-full border rounded-lg px-3 py-2 text-sm font-mono" />
            </div>
            <div class="flex items-center gap-4">
              <label class="flex items-center gap-2 text-sm">
                <input name="supports_reasoning" type="checkbox" value="true"
                       checked={@editing && @editing.supports_reasoning} />
                Reasoning
              </label>
              <label class="flex items-center gap-2 text-sm">
                <input name="supports_tools" type="checkbox" value="true"
                       checked={!@editing || @editing.supports_tools} />
                Tools
              </label>
            </div>
            <div>
              <label class="block text-xs text-gray-500 mb-1">Position</label>
              <input name="position" type="number" value={if @editing, do: @editing.position, else: 0}
                     class="w-full border rounded-lg px-3 py-2 text-sm" />
            </div>
            <div class="col-span-2 flex items-center gap-3">
              <button type="submit" class="bg-gray-900 hover:bg-gray-800 text-white rounded-lg px-4 py-2 text-sm font-medium">
                <%= if @editing, do: "Update", else: "Add" %>
              </button>
              <button :if={@editing} type="button" phx-click="cancel" class="text-sm text-gray-500 hover:text-gray-900">Cancel</button>
              <span :if={@saved} class="text-sm text-green-600">Saved</span>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  defp parse_int(nil, default), do: default
  defp parse_int("", default), do: default
  defp parse_int(val, default) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end
end
```

The `format_number/1` helper is defined in the module:
```elixir
defp format_number(n), do: n |> Integer.to_string() |> String.replace(~r/(\d)(?=(\d{3})+$)/, "\\1,")
```
Add this to the module's private functions.

- [ ] **Step 3: Verify the page loads**

Run: `cd v3 && mix phx.server`
Visit: `http://localhost:4000/models`
Expected: table of existing models with edit/add form

- [ ] **Step 4: Commit**

```
git add v3/apps/druzhok_web/lib/druzhok_web_web/live/models_live.ex v3/apps/druzhok_web/lib/druzhok_web_web/router.ex
```
Message: `add Model Profiles dashboard page`

---

### Task 10: Dashboard — Budget ratio settings

**Files:**
- Modify: `v3/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex`

- [ ] **Step 1: Add budget ratios section to SettingsLive**

In `v3/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex`:

Add to `mount/3` assigns:
```elixir
system_prompt_ratio: Druzhok.Settings.get("system_prompt_budget_ratio") || "0.15",
tool_definitions_ratio: Druzhok.Settings.get("tool_definitions_budget_ratio") || "0.05",
history_ratio: Druzhok.Settings.get("history_budget_ratio") || "0.50",
tool_results_ratio: Druzhok.Settings.get("tool_result_budget_ratio") || "0.20",
response_reserve_ratio: Druzhok.Settings.get("response_reserve_ratio") || "0.10",
default_context_window: Druzhok.Settings.get("default_context_window") || "32000",
token_estimation_divisor: Druzhok.Settings.get("token_estimation_divisor") || "4",
```

Add to `handle_event("save", ...)`:
```elixir
for key <- ["system_prompt_budget_ratio", "tool_definitions_budget_ratio",
            "history_budget_ratio", "tool_result_budget_ratio",
            "response_reserve_ratio", "default_context_window",
            "token_estimation_divisor"] do
  if val = non_empty(params[key]) do
    Druzhok.Settings.set(key, val)
  end
end
```

Add to render, after the Anthropic section:
```html
<div class="bg-white rounded-xl border border-gray-200 p-6">
  <h2 class="text-sm font-semibold mb-4">Token Budget Ratios</h2>
  <p class="text-xs text-gray-500 mb-4">Must sum to 1.0 or less. Controls how the context window is divided.</p>
  <div class="grid grid-cols-2 gap-3">
    <div>
      <label class="block text-xs text-gray-500 mb-1">System Prompt</label>
      <input name="system_prompt_budget_ratio" value={@system_prompt_ratio}
             class="w-full border rounded-lg px-3 py-2 text-sm font-mono" />
    </div>
    <div>
      <label class="block text-xs text-gray-500 mb-1">Tool Definitions</label>
      <input name="tool_definitions_budget_ratio" value={@tool_definitions_ratio}
             class="w-full border rounded-lg px-3 py-2 text-sm font-mono" />
    </div>
    <div>
      <label class="block text-xs text-gray-500 mb-1">Conversation History</label>
      <input name="history_budget_ratio" value={@history_ratio}
             class="w-full border rounded-lg px-3 py-2 text-sm font-mono" />
    </div>
    <div>
      <label class="block text-xs text-gray-500 mb-1">Tool Results</label>
      <input name="tool_result_budget_ratio" value={@tool_results_ratio}
             class="w-full border rounded-lg px-3 py-2 text-sm font-mono" />
    </div>
    <div>
      <label class="block text-xs text-gray-500 mb-1">Response Reserve</label>
      <input name="response_reserve_ratio" value={@response_reserve_ratio}
             class="w-full border rounded-lg px-3 py-2 text-sm font-mono" />
    </div>
    <div>
      <label class="block text-xs text-gray-500 mb-1">Default Context Window</label>
      <input name="default_context_window" value={@default_context_window}
             class="w-full border rounded-lg px-3 py-2 text-sm font-mono" />
    </div>
    <div>
      <label class="block text-xs text-gray-500 mb-1">Token Estimation Divisor</label>
      <input name="token_estimation_divisor" value={@token_estimation_divisor}
             class="w-full border rounded-lg px-3 py-2 text-sm font-mono" />
    </div>
  </div>
</div>
```

- [ ] **Step 2: Verify settings page**

Run: `cd v3 && mix phx.server`
Visit: `http://localhost:4000/settings`
Expected: new "Token Budget Ratios" section visible

- [ ] **Step 3: Commit**

```
git add v3/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex
```
Message: `add budget ratio settings to dashboard`

---

### Task 11: Integration test — full budget flow

**Files:**
- Modify: `v3/apps/pi_core/test/pi_core/session_test.exs`

- [ ] **Step 1: Add budget integration test to session tests**

Add to the existing session test file:

```elixir
test "session uses token budget for compaction" do
  workspace = setup_workspace()
  mock_llm = fn _opts -> {:ok, %Result{content: "response", tool_calls: []}} end

  {:ok, pid} = PiCore.Session.start_link(%{
    workspace: workspace,
    model: "test-model",
    api_url: "http://localhost",
    api_key: "test",
    llm_fn: mock_llm,
    caller: self(),
    model_info_fn: fn :context_window, _ -> 8_000 end
  })

  # Send enough messages to trigger compaction on small model
  for _ <- 1..25 do
    PiCore.Session.prompt(pid, String.duplicate("a", 200))
    assert_receive {:pi_response, _}, 5_000
  end

  # Session should still be functional (compaction handled gracefully)
  PiCore.Session.prompt(pid, "still working?")
  assert_receive {:pi_response, %{text: "response"}}, 5_000
end
```

- [ ] **Step 2: Run the test**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/session_test.exs`
Expected: PASS

- [ ] **Step 3: Run full test suite**

Run: `cd v3 && mix test`
Expected: all PASS

- [ ] **Step 4: Commit**

```
git add v3/apps/pi_core/test/pi_core/session_test.exs
```
Message: `add budget integration test for session compaction`

---

### Task 12: Final cleanup and full test run

- [ ] **Step 1: Run full test suite**

Run: `cd v3 && mix test`
Expected: all PASS

- [ ] **Step 2: Check for compiler warnings**

Run: `cd v3 && mix compile --warnings-as-errors`
Expected: no warnings

- [ ] **Step 3: Verify existing bots still work**

If you have a running instance, send it a few test messages to verify the budget system doesn't break normal operation. The budget should be transparent — same behavior with proportional caps applied.

- [ ] **Step 4: Final commit if any cleanup needed**

Message: `fix warnings and cleanup from token optimization`
