defmodule PiCore.Native.Readability do
  @moduledoc "Stub for readability NIF — falls back to regex-based tag stripping."

  def extract(_html), do: {:error, "readability NIF not available"}

  def strip_tags(html) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
  def strip_tags(_), do: ""
end
