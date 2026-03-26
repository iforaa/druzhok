defmodule Druzhok.PromptGuard do
  @moduledoc """
  Guards that run before an LLM call. Returns {:ok} or {:reject, reason}.
  Add all pre-prompt checks here: budget limits, rate limits, content filters, etc.
  """

  def check(instance_name) do
    with :ok <- check_token_budget(instance_name) do
      :ok
    end
  end

  defp check_token_budget(instance_name) do
    if Druzhok.TokenBudget.budget_exceeded?(instance_name) do
      {:reject, "⚠️ Дневной лимит токенов исчерпан. Попробуй завтра."}
    else
      :ok
    end
  end
end
