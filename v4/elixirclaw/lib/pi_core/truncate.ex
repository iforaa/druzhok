defmodule PiCore.Truncate do
  @moduledoc """
  Head+tail truncation that preserves beginnings and ends of text.
  Snaps to newline boundaries to avoid partial lines.
  """

  @min_max_chars 200

  def head_tail(text, max_chars, head_ratio \\ 0.7, tail_ratio \\ 0.2)
  def head_tail(nil, _max_chars, _head_ratio, _tail_ratio), do: ""
  def head_tail(text, max_chars, head_ratio, tail_ratio) when is_binary(text) do
    max_chars = max(max_chars, @min_max_chars)

    if byte_size(text) <= max_chars * 1.1 do
      text
    else
      do_truncate(text, max_chars, head_ratio, tail_ratio)
    end
  end

  defp do_truncate(text, max_chars, head_ratio, tail_ratio) do
    marker = "\n\n... [truncated — original was #{byte_size(text)} bytes, showing first/last portions] ...\n\n"
    marker_size = byte_size(marker)
    available = max_chars - marker_size

    if available <= 0 do
      String.slice(text, 0, max_chars)
    else
      head_size = trunc(available * head_ratio)
      tail_size = trunc(available * tail_ratio)

      head = text |> String.slice(0, head_size) |> snap_to_newline_end()
      tail = text |> String.slice(-tail_size, tail_size) |> snap_to_newline_start()

      head <> marker <> tail
    end
  end

  defp snap_to_newline_end(text) do
    case String.split(text, "\n") do
      [single] -> single
      parts -> parts |> Enum.drop(-1) |> Enum.join("\n")
    end
  end

  defp snap_to_newline_start(text) do
    case String.split(text, "\n", parts: 2) do
      [_partial, rest] -> rest
      [single] -> single
    end
  end
end
