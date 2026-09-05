defmodule Druzhok.ModelAccess do
  @moduledoc """
  Plan-based model gating. Checks if a model is allowed for a tenant,
  and provides downgrade logic.
  """

  @model_tiers %{
    "claude-haiku" => 1,
    "claude-haiku-3-5" => 1,
    "claude-haiku-4-5" => 1,
    "deepseek-r1" => 1,
    "deepseek-chat" => 1,
    "gpt-4o-mini" => 1,
    "claude-sonnet" => 2,
    "claude-sonnet-4-20250514" => 2,
    "claude-sonnet-4-6" => 2,
    "gpt-4o" => 2,
    "claude-opus" => 3,
    "claude-opus-4-6" => 3,
  }

  @plan_max_tier %{
    "free" => 1,
    "pro" => 2,
    "enterprise" => 3,
  }

  def check(plan, requested_model) do
    max_tier = Map.get(@plan_max_tier, to_string(plan), 1)
    model_tier = get_tier(requested_model)

    if model_tier <= max_tier do
      {:ok, requested_model}
    else
      {:downgrade, best_allowed(requested_model, max_tier)}
    end
  end

  defp get_tier(model) do
    Map.get(@model_tiers, model) ||
      Enum.find_value(@model_tiers, 1, fn {prefix, tier} ->
        if String.starts_with?(model, prefix), do: tier
      end)
  end

  defp best_allowed(requested_model, max_tier) do
    family = model_family(requested_model)

    @model_tiers
    |> Enum.filter(fn {name, tier} -> tier <= max_tier and model_family(name) == family end)
    |> Enum.sort_by(fn {_, tier} -> -tier end)
    |> case do
      [{name, _} | _] -> name
      [] -> "claude-haiku"
    end
  end

  defp model_family(model) do
    cond do
      String.contains?(model, "claude") -> :claude
      String.contains?(model, "gpt") -> :openai
      String.contains?(model, "deepseek") -> :deepseek
      true -> :other
    end
  end
end
