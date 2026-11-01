defmodule Druzhok.Lifecycle.StartGate do
  @moduledoc """
  What stands between a controller and a bot start that needs new memory: one
  start at a time, and only with `start_min_free_mb` of `MemAvailable` left.
  Being refused is not a failure: the controller just tries again on its next
  tick, so there is no queue and no order. The lock goes with its holder when
  that process dies.
  """

  @default_min_free_mb 900
  @meminfo "/proc/meminfo"

  @doc "`fun.()`, or `{:busy, :lock | {:memory, free_mb}}` without running it."
  def with_slot(fun) when is_function(fun, 0) do
    inner = fn ->
      free = free_mb()
      if free && free < min_free_mb(), do: {:busy, {:memory, free}}, else: fun.()
    end

    case :global.trans({__MODULE__, self()}, inner, [node()], 0) do
      :aborted -> {:busy, :lock}
      result -> result
    end
  end

  # nil when there is no reading (macOS dev): the memory check passes.
  defp free_mb do
    with {:ok, text} <- File.read(opt(:meminfo_path) || @meminfo),
         [_, kb] <- Regex.run(~r/^MemAvailable:\s+(\d+)\s+kB/m, text) do
      div(String.to_integer(kb), 1024)
    else
      _ -> nil
    end
  end

  @doc "The `MemAvailable` a start needs, in MB."
  def min_free_mb do
    case opt(:start_min_free_mb) do
      mb when is_integer(mb) -> mb
      _ -> min_free_from_settings()
    end
  end

  defp min_free_from_settings do
    case Integer.parse(to_string(Druzhok.Settings.get("start_min_free_mb") || "")) do
      {mb, ""} when mb > 0 -> mb
      _ -> @default_min_free_mb
    end
  end

  defp opt(key), do: Keyword.get(Application.get_env(:druzhok, :lifecycle, []), key)
end
