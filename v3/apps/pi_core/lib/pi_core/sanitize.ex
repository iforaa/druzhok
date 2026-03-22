defmodule PiCore.Sanitize do
  @moduledoc """
  Strips model-specific artifacts from LLM output.
  Handles pipe-delimited tokens, Minimax XML, and thinking tags.
  """

  def strip_artifacts(text) do
    text
    |> then(&Regex.replace(~r/<[|｜][^|｜]+_begin[|｜]>.*?<[|｜][^|｜]+_end[|｜]>/s, &1, ""))
    |> then(&Regex.replace(~r/<[|｜][^|｜]*[|｜]>/s, &1, ""))
    |> then(&Regex.replace(~r/<invoke\b[^>]*>[\s\S]*?<\/invoke>/i, &1, ""))
    |> then(&Regex.replace(~r/<\/?minimax:tool_call>/i, &1, ""))
    |> then(&Regex.replace(~r/<\s*\/?(?:think(?:ing)?|thought|antthinking)\s*>/i, &1, ""))
    |> String.trim()
  end
end
