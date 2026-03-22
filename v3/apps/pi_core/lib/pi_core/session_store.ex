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
