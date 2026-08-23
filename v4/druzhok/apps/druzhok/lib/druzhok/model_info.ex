defmodule Druzhok.ModelInfo do
  @default_context_window 32_000

  def context_window(model_name) do
    case lookup(model_name) do
      nil -> default_context_window()
      model -> model.context_window || default_context_window()
    end
  end

  def supports_reasoning?(model_name) do
    case lookup(model_name) do
      nil -> false
      model -> model.supports_reasoning || false
    end
  end

  def supports_tools?(model_name) do
    case lookup(model_name) do
      nil -> true
      model -> model.supports_tools
    end
  end

  def supports_vision?(model_name) do
    case lookup(model_name) do
      nil -> false
      model -> model.supports_vision || false
    end
  end

  # Try the full id first, then every provider-stripped suffix
  # ("nebius/deepseek-ai/X" → "deepseek-ai/X" → "X").
  defp lookup(model_name) when is_binary(model_name) do
    model_name
    |> candidates()
    |> Enum.find_value(fn id -> Druzhok.Repo.get_by(Druzhok.Model, model_id: id) end)
  end

  defp candidates(model_name) do
    parts = String.split(model_name, "/")
    for i <- 0..(length(parts) - 1), do: parts |> Enum.drop(i) |> Enum.join("/")
  end

  defp default_context_window do
    case Druzhok.Settings.get("default_context_window") do
      nil -> @default_context_window
      val -> String.to_integer(val)
    end
  end
end
