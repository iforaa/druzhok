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

  defp lookup(model_name) do
    stripped = strip_provider(model_name)
    case Druzhok.Repo.get_by(Druzhok.Model, model_id: model_name) do
      nil -> Druzhok.Repo.get_by(Druzhok.Model, model_id: stripped)
      model -> model
    end
  end

  defp strip_provider(model_name) when is_binary(model_name) do
    case String.split(model_name, "/", parts: 2) do
      [_provider, model] -> model
      [model] -> model
    end
  end

  defp default_context_window do
    case Druzhok.Settings.get("default_context_window") do
      nil -> @default_context_window
      val -> String.to_integer(val)
    end
  end
end
