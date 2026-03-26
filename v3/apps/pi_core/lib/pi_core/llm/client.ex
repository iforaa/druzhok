defmodule PiCore.LLM.Client do
  @moduledoc """
  Routes LLM requests to the appropriate provider client.
  All providers return the same Result struct.
  """

  defmodule Result do
    defstruct content: "", tool_calls: [], reasoning: "",
              input_tokens: 0, output_tokens: 0,
              cache_read_tokens: 0, cache_write_tokens: 0
  end

  def completion(opts) do
    case detect_provider(opts) do
      :anthropic -> PiCore.LLM.Anthropic.completion(opts)
      _ -> PiCore.LLM.OpenAI.completion(opts)
    end
  end

  def detect_provider(opts) do
    cond do
      opts[:provider] == "anthropic" -> :anthropic
      String.starts_with?(opts[:model] || "", "claude") -> :anthropic
      String.contains?(opts[:api_url] || "", "anthropic") -> :anthropic
      true -> :openai
    end
  end
end
