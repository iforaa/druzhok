defmodule Druzhok.Lifecycle.StartGate do
  @moduledoc """
  What stands between a controller and a bot start that needs new memory: one
  start at a time, and only with `start_min_free_mb` of `MemAvailable` left.
  Being refused is not a failure: the controller just tries again on its next
  tick, so there is no queue and no order. The lock goes with its holder when
  that process dies.

  In queue mode (`Lifecycle.Queue`) only the lock is kept: `bot_slots` sized to
  the slice's `MemoryMax` already guarantees the memory, and the extra veto
  stalled the line (bot queue spec, "Slots").
  """

  @default_min_free_mb 900

  @doc "`fun.()`, or `{:busy, :lock | {:memory, free_mb}}` without running it."
  def with_slot(fun) when is_function(fun, 0) do
    inner = fn ->
      free = if Druzhok.Lifecycle.Queue.on?(), do: nil, else: free_mb()
      if free && free < min_free_mb(), do: {:busy, {:memory, free}}, else: fun.()
    end

    case :global.trans({__MODULE__, self()}, inner, [node()], 0) do
      :aborted -> {:busy, :lock}
      result -> result
    end
  end

  # nil when there is no reading (macOS dev): the memory check passes.
  defp free_mb, do: Druzhok.MemInfo.available_mb(opt(:meminfo_path))

  @doc "The `MemAvailable` a start needs, in MB."
  def min_free_mb do
    case opt(:start_min_free_mb) do
      mb when is_integer(mb) -> mb
      _ -> Druzhok.Settings.positive_int("start_min_free_mb", @default_min_free_mb)
    end
  end

  defp opt(key), do: Keyword.get(Application.get_env(:druzhok, :lifecycle, []), key)
end
