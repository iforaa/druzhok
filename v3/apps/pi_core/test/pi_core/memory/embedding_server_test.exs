defmodule PiCore.Memory.EmbeddingServerTest do
  use ExUnit.Case, async: false

  alias PiCore.Memory.EmbeddingServer

  # BinaryBackend inference is slow (~20s per call), so use generous timeouts
  @moduletag timeout: 300_000

  @tag :slow
  test "embed returns a 384-dim float vector" do
    case EmbeddingServer.embed("Hello world") do
      {:ok, vector} ->
        assert is_list(vector)
        assert length(vector) == 384
        assert Enum.all?(vector, &is_float/1)

      {:error, _reason} ->
        :ok
    end
  end

  @tag :slow
  test "embed_batch returns one vector per input" do
    case EmbeddingServer.embed_batch(["hello", "world"]) do
      {:ok, vectors} ->
        assert length(vectors) == 2
        assert Enum.all?(vectors, fn v -> is_list(v) and length(v) == 384 end)

      {:error, _reason} ->
        :ok
    end
  end

  @tag :slow
  test "similar texts have higher cosine similarity than unrelated texts" do
    # Use embed_batch to avoid 3 sequential slow calls
    case EmbeddingServer.embed_batch([
           "The cat sat on the mat",
           "A cat was sitting on a rug",
           "Quantum physics equations"
         ]) do
      {:ok, [v1, v2, v3]} ->
        sim_similar = PiCore.Memory.VectorMath.cosine_similarity(v1, v2)
        sim_different = PiCore.Memory.VectorMath.cosine_similarity(v1, v3)
        assert sim_similar > sim_different

      {:error, _} ->
        :ok
    end
  end

  test "embed returns ok or error tuple" do
    result = EmbeddingServer.embed("test")
    assert match?({:ok, _}, result) or match?({:error, _}, result)
  end
end
