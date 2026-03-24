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
        {media_type, data} = parse_data_url(url)
        %{type: "image", source: %{type: "base64", media_type: media_type, data: data}}

      other ->
        %{type: "text", text: inspect(other)}
    end)
  end

  defp parse_data_url("data:" <> rest) do
    case String.split(rest, ";base64,", parts: 2) do
      [media_type, data] -> {media_type, data}
      _ -> {"application/octet-stream", rest}
    end
  end
  defp parse_data_url(url), do: {"image/jpeg", url}
end
