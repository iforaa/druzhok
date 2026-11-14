defmodule Druzhok.MemInfo do
  @moduledoc """
  `MemAvailable` from `/proc/meminfo`, in MB. Shared by the bot start gate
  (`Lifecycle.StartGate`) and the document converter (`Druzhok.Docs`).
  """

  @meminfo "/proc/meminfo"

  @doc "MB available, or nil when there is no reading (macOS dev): callers let that pass."
  def available_mb(path \\ nil) do
    with {:ok, text} <- File.read(path || @meminfo),
         [_, kb] <- Regex.run(~r/^MemAvailable:\s+(\d+)\s+kB/m, text) do
      div(String.to_integer(kb), 1024)
    else
      _ -> nil
    end
  end
end
