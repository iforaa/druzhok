defmodule PiCore.SessionStore do
  @filename "session.jsonl"

  def save(dir, messages) do
    path = Path.join(dir, @filename)
    content = messages |> Enum.map(&encode_message/1) |> Enum.join("\n")
    File.write!(path, content <> "\n")
  end

  def append(dir, message) do
    path = Path.join(dir, @filename)
    File.write!(path, encode_message(message) <> "\n", [:append])
  end

  def load(dir) do
    path = Path.join(dir, @filename)
    case File.read(path) do
      {:ok, content} ->
        content |> String.split("\n", trim: true) |> Enum.map(&decode_message/1) |> Enum.reject(&is_nil/1)
      {:error, _} -> []
    end
  end

  def clear(dir) do
    Path.join(dir, @filename) |> File.rm()
  end

  def sanitize_for_persistence(messages, budget) when is_struct(budget, PiCore.TokenBudget) do
    max_chars = PiCore.TokenBudget.per_tool_result_cap(budget) * 4 * 2
    Enum.map(messages, fn msg ->
      if msg.role == "toolResult" and is_binary(msg.content) and byte_size(msg.content) > max_chars do
        %{msg | content: PiCore.Truncate.head_tail(msg.content, max_chars)}
      else
        msg
      end
    end)
  end
  def sanitize_for_persistence(messages, _), do: messages

  defp encode_message(msg) when is_map(msg) do
    Jason.encode!(msg)
  end

  defp decode_message(line) do
    case Jason.decode(line) do
      {:ok, data} -> data
      _ -> nil
    end
  end
end
