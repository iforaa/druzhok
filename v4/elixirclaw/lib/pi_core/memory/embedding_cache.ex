defmodule PiCore.Memory.EmbeddingCache do
  @callback get(instance_name :: String.t(), chunk_hash :: String.t()) :: {:ok, [float()]} | :miss
  @callback put(instance_name :: String.t(), entry :: map()) :: :ok
  @callback delete_missing_files(instance_name :: String.t(), current_files :: [String.t()]) :: :ok
end
