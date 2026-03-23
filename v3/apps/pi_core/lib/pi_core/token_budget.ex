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
