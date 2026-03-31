defmodule PiCore.Multimodal do
  @moduledoc """
  Helpers for multimodal content (images in messages).
  Content can be a string (text only) or a list of content parts (multimodal).
  """

  def is_multimodal?(content) when is_list(content), do: true
  def is_multimodal?(_), do: false

  @doc "Convert content (string or list) to plain text, replacing images with placeholders."
  def to_text(nil), do: ""
  def to_text(content) when is_binary(content), do: content
  def to_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      %{"type" => "image_url"} -> "[изображение]"
      %{"type" => "input_audio"} -> "[аудио]"
      _ -> ""
    end)
    |> Enum.reject(& &1 == "")
    |> Enum.join("\n")
  end

  @doc "Convert OpenAI-format content array to Anthropic content blocks."
  def to_anthropic_content(content) when is_list(content) do
    Enum.map(content, fn
      %{"type" => "text", "text" => text} ->
        %{type: "text", text: text}

      %{"type" => "image_url", "image_url" => %{"url" => url}} ->
        case parse_data_url(url) do
          {:ok, media_type, data} ->
            %{type: "image", source: %{type: "base64", media_type: media_type, data: data}}
          {:error, _} ->
            %{type: "text", text: "[image: invalid data URL]"}
        end

      other ->
        %{type: "text", text: inspect(other)}
    end)
  end

  @doc "Parse a data URL into {media_type, base64_data}."
  def parse_data_url("data:" <> rest) do
    case String.split(rest, ";base64,", parts: 2) do
      [media_type, data] -> {:ok, media_type, data}
      _ -> {:error, "Invalid data URL format"}
    end
  end
  def parse_data_url(_), do: {:error, "Not a data URL"}
end
