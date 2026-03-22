defmodule PiCore.LLM.Client do
  @moduledoc """
  Routes LLM requests to the appropriate provider client.
  All providers return the same Result struct.
  """

  defmodule Result do
    defstruct content: "", tool_calls: [], reasoning: ""
  end

  def completion(opts) do
    provider = opts[:provider] || detect_provider(opts)

    case provider do
      :anthropic -> PiCore.LLM.Anthropic.completion(opts)
      _ -> PiCore.LLM.OpenAI.completion(opts)
    end
  end

  defp detect_provider(opts) do
    model = opts[:model] || ""
    api_url = opts[:api_url] || ""

    cond do
      String.starts_with?(model, "claude") -> :anthropic
      String.contains?(api_url, "anthropic") -> :anthropic
      true -> :openai
    end
  end
end
