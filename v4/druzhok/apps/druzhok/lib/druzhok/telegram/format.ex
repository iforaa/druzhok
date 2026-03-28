defmodule Druzhok.Telegram.Format do
  @moduledoc """
  Converts markdown from LLM output to Telegram HTML.
  Escapes HTML first, then applies formatting tags.
  """

  def to_telegram_html(text) do
    text
    |> escape_html()
    |> convert_code_blocks()
    |> convert_inline_code()
    |> convert_bold()
    |> convert_italic()
    |> convert_strikethrough()
    |> strip_headers()
  end

  defp escape_html(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # ```code blocks``` → <pre>code</pre>
  defp convert_code_blocks(text) do
    Regex.replace(~r/```\w*\n?(.*?)```/s, text, "<pre>\\1</pre>")
  end

  # `inline code` → <code>code</code>
  defp convert_inline_code(text) do
    Regex.replace(~r/`([^`]+)`/, text, "<code>\\1</code>")
  end

  # **bold** → <b>bold</b>
  defp convert_bold(text) do
    Regex.replace(~r/\*\*(.+?)\*\*/s, text, "<b>\\1</b>")
  end

  # *italic* → <i>italic</i> (but not inside words)
  defp convert_italic(text) do
    Regex.replace(~r/(?<!\w)\*(?!\*)(.+?)(?<!\*)\*(?!\w)/s, text, "<i>\\1</i>")
  end

  # ~~strikethrough~~ → <s>text</s>
  defp convert_strikethrough(text) do
    Regex.replace(~r/~~(.+?)~~/s, text, "<s>\\1</s>")
  end

  # Strip # headers (keep text)
  defp strip_headers(text) do
    Regex.replace(~r/^\#{1,6}\s+/m, text, "")
  end
end
