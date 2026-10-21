defmodule DruzhokWebWeb.LlmFormat do
  @moduledoc """
  Message helpers for the ruoc proxy path (`LlmProxy.Ruoc`): token usage,
  the prompt preview stored in `usage_logs`, and image stripping for models
  that cannot see.
  """

  def extract_usage(body) do
    usage = body["usage"] || %{}
    %{prompt_tokens: usage["prompt_tokens"] || 0, completion_tokens: usage["completion_tokens"] || 0}
  end

  @doc "Text of the last message, capped at 500 chars, for `usage_logs.prompt_preview`."
  def prompt_preview(%{"messages" => [_ | _] = msgs}) do
    case msgs |> List.last() |> Map.get("content", "") do
      text when is_binary(text) ->
        String.slice(text, 0, 500)

      parts when is_list(parts) ->
        parts
        |> Enum.filter(&(&1["type"] == "text"))
        |> Enum.map_join(" ", &(&1["text"] || ""))
        |> String.slice(0, 500)

      _ ->
        nil
    end
  end

  def prompt_preview(_), do: nil

  @doc "Drop image parts and flatten the message to text, for models that cannot see."
  def strip_images(messages) when is_list(messages) do
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

  def strip_images(other), do: other
end
