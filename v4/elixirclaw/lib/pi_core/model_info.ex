defmodule PiCore.ModelInfo do
  @callback context_window(model_name :: String.t()) :: pos_integer()
  @callback supports_reasoning?(model_name :: String.t()) :: boolean()
  @callback supports_tools?(model_name :: String.t()) :: boolean()

  def strip_provider(model_id) do
    model_id
    |> String.split("/")
    |> List.last()
  end
end
