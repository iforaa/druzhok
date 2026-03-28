defmodule DruzhokWebWeb.LlmFormat do
  @moduledoc """
  Routes all LLM requests through OpenRouter. Strips images from messages
  when the target model doesn't support vision.
  """

  @non_vision_models [
    "deepseek/deepseek-v3.2",
    "deepseek/deepseek-chat",
    "deepseek/deepseek-r1",
    "minimax/minimax-m2.5",
    "minimax/minimax-m2.7",
  ]

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

  def prepare_body(body) do
    model = body["model"] || ""
    if model in @non_vision_models do
      Map.update(body, "messages", [], &strip_images/1)
    else
      body
    end
  end

  defp strip_images(messages) when is_list(messages) do
    Enum.map(messages, fn msg ->
      case msg["content"] do
        parts when is_list(parts) ->
          cleaned = Enum.reject(parts, &(&1["type"] == "image_url"))
          text = Enum.map_join(cleaned, "\n", fn
            %{"type" => "text", "text" => t} -> t
            other -> inspect(other)
          end)
          Map.put(msg, "content", text)
        _ ->
          msg
      end
    end)
  end
end
