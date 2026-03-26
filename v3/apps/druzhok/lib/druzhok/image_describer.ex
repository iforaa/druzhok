defmodule Druzhok.ImageDescriber do
  @moduledoc "Describes images using a cheap vision model via OpenRouter."

  @vision_model "google/gemini-2.5-flash"
  @max_tokens 300

  def describe(image_url) do
    api_key = Druzhok.Settings.api_key("openrouter")
    api_url = Druzhok.Settings.api_url("openrouter") || "https://openrouter.ai/api/v1"

    unless api_key do
      {:error, "No OpenRouter API key"}
    else
      messages = [%{
        role: "user",
        content: [
          %{type: "image_url", image_url: %{url: image_url}},
          %{type: "text", text: "Describe this image concisely in 1-3 sentences. Focus on what's shown: text, UI elements, objects, people, scene. Be factual."}
        ]
      }]

      case PiCore.LLM.OpenAI.completion(%{
        model: @vision_model,
        api_url: api_url,
        api_key: api_key,
        provider: "openrouter",
        system_prompt: "You describe images concisely.",
        messages: messages,
        tools: [],
        max_tokens: @max_tokens,
        stream: false
      }) do
        {:ok, result} when result.content != "" -> {:ok, result.content}
        {:ok, _} -> {:error, "Empty description"}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
