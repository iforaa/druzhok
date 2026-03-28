defmodule DruzhokWebWeb.LlmFormat do
  @moduledoc """
  Routes models to providers and translates between OpenAI and Anthropic formats.
  OpenRouter and Nebius accept OpenAI format natively.
  """

  def route_provider(model) do
    cond do
      String.starts_with?(model, "claude") -> :anthropic
      String.starts_with?(model, "gpt") -> :openrouter
      String.starts_with?(model, "deepseek") -> :nebius
      String.starts_with?(model, "glm") -> :nebius
      String.starts_with?(model, "Qwen") -> :nebius
      true -> :openrouter
    end
  end

  def provider_url(provider) do
    case provider do
      :anthropic -> Application.get_env(:druzhok, :anthropic_api_url) || "https://api.anthropic.com"
      :openrouter -> Application.get_env(:druzhok, :openrouter_api_url) || "https://openrouter.ai/api/v1"
      :nebius -> Application.get_env(:druzhok, :nebius_api_url) || "https://api.tokenfactory.us-central1.nebius.com/v1"
    end
  end

  def provider_key(provider) do
    case provider do
      :anthropic -> Application.get_env(:druzhok, :anthropic_api_key)
      :openrouter -> Application.get_env(:druzhok, :openrouter_api_key)
      :nebius -> Application.get_env(:druzhok, :nebius_api_key)
    end
  end

  def build_request(:anthropic, body) do
    messages = body["messages"] || []
    {system_msgs, chat_msgs} = Enum.split_with(messages, &(&1["role"] == "system"))
    system_text = system_msgs |> Enum.map(& &1["content"]) |> Enum.join("\n\n")

    anthropic_body = %{
      "model" => body["model"],
      "messages" => chat_msgs,
      "max_tokens" => body["max_tokens"] || 4096,
      "stream" => body["stream"] || false,
    }

    anthropic_body = if system_text != "", do: Map.put(anthropic_body, "system", system_text), else: anthropic_body
    if body["temperature"], do: Map.put(anthropic_body, "temperature", body["temperature"]), else: anthropic_body
  end

  def build_request(_provider, body), do: body

  def request_path(:anthropic), do: "/v1/messages"
  def request_path(_), do: "/v1/chat/completions"

  def request_headers(:anthropic, api_key) do
    [
      {"x-api-key", api_key},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"},
    ]
  end

  def request_headers(_, api_key) do
    [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"},
    ]
  end

  def extract_usage(:anthropic, body) do
    usage = body["usage"] || %{}
    %{prompt_tokens: usage["input_tokens"] || 0, completion_tokens: usage["output_tokens"] || 0}
  end

  def extract_usage(_, body) do
    usage = body["usage"] || %{}
    %{prompt_tokens: usage["prompt_tokens"] || 0, completion_tokens: usage["completion_tokens"] || 0}
  end
end
