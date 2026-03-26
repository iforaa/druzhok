defmodule Druzhok.DreamDigest do
  @moduledoc "Builds a conversation digest from session JSONL files for the dreaming prompt."

  @max_messages_per_session 30
  @max_content_chars 500
  @max_total_chars 16_000

  def build(workspace) do
    sessions_dir = Path.join(workspace, "sessions")

    case File.ls(sessions_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(fn file -> {file, Path.join(sessions_dir, file)} end)
        |> Enum.map(fn {name, path} -> {name, parse_session(path)} end)
        |> Enum.reject(fn {_, msgs} -> msgs == [] end)
        |> format_digest()

      {:error, _} -> ""
    end
  end

  defp parse_session(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&decode_line/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(fn msg -> msg["role"] in ["user", "assistant"] end)
        |> Enum.reject(fn msg ->
          content = msg["content"] || ""
          String.starts_with?(content, "HEARTBEAT") or
            String.starts_with?(content, "[System:")
        end)
        |> Enum.take(-@max_messages_per_session)

      {:error, _} -> []
    end
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{"role" => _} = msg} -> msg
      _ -> nil
    end
  end

  defp format_digest(sessions) do
    {result, _total} = Enum.reduce(sessions, {"", 0}, fn {name, msgs}, {acc, total} ->
      if total >= @max_total_chars do
        {acc, total}
      else
        chat_id = name |> String.replace(".jsonl", "")
        section = "--- Chat #{chat_id} ---\n" <>
          Enum.map_join(msgs, "\n", fn msg ->
            content = msg["content"] || ""
            truncated = String.slice(content, 0, @max_content_chars)
            "[#{msg["role"]}] #{truncated}"
          end) <> "\n\n"

        new_total = total + byte_size(section)
        if new_total > @max_total_chars do
          {acc, total}
        else
          {acc <> section, new_total}
        end
      end
    end)
    result
  end
end
