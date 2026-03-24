defmodule PiCore.SessionStore do
  @max_messages 500
  @version 1

  def save(workspace, chat_id, messages) do
    path = session_path(workspace, chat_id)
    ensure_dir(path)
    capped = cap_messages(messages)
    header = encode_header(chat_id)
    content = [header | Enum.map(capped, &encode_message/1)] |> Enum.join("\n")
    write_atomic(path, content <> "\n")
  end

  def truncate_after_compaction(workspace, chat_id, compacted_messages) do
    save(workspace, chat_id, compacted_messages)
  end

  def append_many(workspace, chat_id, messages) do
    path = session_path(workspace, chat_id)
    ensure_dir(path)

    content = if File.exists?(path) do
      messages |> Enum.map(&encode_message/1) |> Enum.join("\n")
    else
      header = encode_header(chat_id)
      [header | Enum.map(messages, &encode_message/1)] |> Enum.join("\n")
    end

    File.write!(path, content <> "\n", [:append])
  end

  def load(workspace, chat_id) do
    path = session_path(workspace, chat_id)
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&decode_line/1)
        |> Enum.reject(fn {type, _} -> type == :header or type == :skip end)
        |> Enum.map(fn {:message, msg} -> msg end)
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

  defp cap_messages(messages) do
    len = length(messages)
    if len > @max_messages, do: Enum.drop(messages, len - @max_messages), else: messages
  end

  defp encode_header(chat_id) do
    Jason.encode!(%{
      type: "session",
      version: @version,
      chat_id: chat_id,
      created_at: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp encode_message(msg) when is_map(msg) do
    Jason.encode!(msg)
  end

  defp write_atomic(path, content) do
    tmp = path <> ".tmp"
    File.write!(tmp, content)
    File.rename!(tmp, path)
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "session"}} -> {:header, nil}
      {:ok, data} -> {:message, data}
      _ -> {:skip, nil}
    end
  end
end
