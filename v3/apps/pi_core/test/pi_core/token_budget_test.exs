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
