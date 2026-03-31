defmodule PiCore.LLM.SSEParser do
  @doc """
  Parse SSE stream data. Returns {parsed_events, remaining_buffer}.
  Events are decoded JSON maps or :done atom.
  """
  def parse(chunk, buffer) do
    full = buffer <> chunk
    lines = String.split(full, "\n")
    {complete_lines, [rest]} = Enum.split(lines, -1)

    events =
      complete_lines
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(&String.trim_leading(&1, "data: "))
      |> Enum.flat_map(fn
        "[DONE]" -> [:done]
        json_str ->
          case Jason.decode(json_str) do
            {:ok, data} -> [data]
            _ -> []
          end
      end)

    {events, rest}
  end
end
