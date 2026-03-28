defmodule DruzhokWebWeb.LlmFormat do
  @moduledoc """
  Routes all LLM requests through OpenRouter. OpenRouter accepts OpenAI format
  natively and supports all major models (Claude, GPT, DeepSeek, etc.).
  No format translation needed.
  """

  def provider_url do
    Application.get_env(:druzhok, :openrouter_api_url) || "https://openrouter.ai/api/v1"
  end

  def provider_key do
    Application.get_env(:druzhok, :openrouter_api_key)
  end

  def request_url, do: provider_url() <> "/chat/completions"

  def request_headers do
    [
      {"authorization", "Bearer #{provider_key()}"},
      {"content-type", "application/json"},
    ]
  end

  def extract_usage(body) do
    usage = body["usage"] || %{}
    %{prompt_tokens: usage["prompt_tokens"] || 0, completion_tokens: usage["completion_tokens"] || 0}
  end
end
