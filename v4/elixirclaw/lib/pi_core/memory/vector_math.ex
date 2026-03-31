defmodule PiCore.Memory.VectorMath do
  @moduledoc "Vector operations for embedding similarity search."

  def cosine_similarity(a, b) when is_list(a) and is_list(b) do
    {dot, norm_a, norm_b} = Enum.zip(a, b)
    |> Enum.reduce({0.0, 0.0, 0.0}, fn {ai, bi}, {dot, na, nb} ->
      {dot + ai * bi, na + ai * ai, nb + bi * bi}
    end)

    denom = :math.sqrt(norm_a) * :math.sqrt(norm_b)
    if denom == 0, do: 0.0, else: dot / denom
  end

  def chunk_hash(text) when is_binary(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end
end
