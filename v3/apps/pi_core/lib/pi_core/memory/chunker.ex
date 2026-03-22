defmodule PiCore.Memory.Chunker do
  @moduledoc """
  Split markdown files into overlapping chunks for embedding.
  ~400 tokens per chunk, ~80 token overlap.
  """

  defmodule Chunk do
    defstruct [:text, :file, :start_line, :end_line]
  end

  @default_target_chars 1600   # ~400 tokens × 4 chars/token
  @default_overlap_chars 320   # ~80 tokens × 4 chars/token

  def chunk_file(text, file, opts \\ []) do
    if String.trim(text) == "", do: [], else: do_chunk(text, file, opts)
  end

  defp do_chunk(text, file, opts) do
    target = opts[:target_chars] || @default_target_chars
    overlap = opts[:overlap_chars] || @default_overlap_chars
    lines = String.split(text, "\n")

    if String.length(text) <= target do
      [%Chunk{text: text, file: file, start_line: 1, end_line: length(lines)}]
    else
      build_chunks(lines, file, target, overlap)
    end
  end

  defp build_chunks(lines, file, target, overlap) do
    chunks = []
    current_start = 0

    do_build(lines, file, target, overlap, chunks, current_start)
  end

  defp do_build(lines, file, target, overlap, chunks, current_start) when current_start >= length(lines) do
    Enum.reverse(chunks)
  end

  defp do_build(lines, file, target, overlap, chunks, current_start) do
    {current_end, _char_count} = accumulate_lines(lines, current_start, target)

    chunk_lines = Enum.slice(lines, current_start, current_end - current_start)
    chunk = %Chunk{
      text: Enum.join(chunk_lines, "\n"),
      file: file,
      start_line: current_start + 1,
      end_line: current_end
    }

    # Advance by target - overlap worth of lines
    advance_chars = target - overlap
    next_start = advance_start(lines, current_start, advance_chars)
    next_start = if next_start <= current_start, do: current_start + 1, else: next_start

    if next_start >= length(lines) do
      Enum.reverse([chunk | chunks])
    else
      do_build(lines, file, target, overlap, [chunk | chunks], next_start)
    end
  end

  defp accumulate_lines(lines, start, target) do
    Enum.reduce_while(start..(length(lines) - 1), {start, 0}, fn i, {_, chars} ->
      new_chars = chars + String.length(Enum.at(lines, i)) + 1
      if new_chars >= target do
        {:halt, {i + 1, new_chars}}
      else
        {:cont, {i + 1, new_chars}}
      end
    end)
  end

  defp advance_start(lines, start, advance_chars) do
    Enum.reduce_while(start..(length(lines) - 1), {start, 0}, fn i, {_, chars} ->
      new_chars = chars + String.length(Enum.at(lines, i)) + 1
      if new_chars >= advance_chars do
        {:halt, {i + 1, new_chars}}
      else
        {:cont, {i + 1, new_chars}}
      end
    end)
    |> elem(0)
  end
end
