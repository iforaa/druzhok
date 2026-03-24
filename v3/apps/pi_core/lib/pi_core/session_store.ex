defmodule PiCore.SessionStore do
  @max_messages 500

  def save(workspace, chat_id, messages) do
    path = session_path(workspace, chat_id)
    ensure_dir(path)
    capped = cap_messages(messages)
    content = capped |> Enum.map(&encode_message/1) |> Enum.join("\n")
    File.write!(path, content <> "\n")
  end

  def append_many(workspace, chat_id, messages) do
    path = session_path(workspace, chat_id)
    ensure_dir(path)
    content = messages |> Enum.map(&encode_message/1) |> Enum.join("\n")
    File.write!(path, content <> "\n", [:append])
  end

  def load(workspace, chat_id) do
    path = session_path(workspace, chat_id)
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&decode_message/1)
        |> Enum.reject(&is_nil/1)
      {:error, _} -> []
    end
  end

  def clear(workspace, chat_id) do
    session_path(workspace, chat_id) |> File.rm()
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

  defp session_path(workspace, chat_id) do
    Path.join([workspace, "sessions", "#{chat_id}.jsonl"])
  end

  defp ensure_dir(path) do
    File.mkdir_p!(Path.dirname(path))
  end

  defp cap_messages(messages) when length(messages) > @max_messages do
    Enum.drop(messages, length(messages) - @max_messages)
  end
  defp cap_messages(messages), do: messages

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
