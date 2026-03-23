defmodule Druzhok.EmbeddingCacheTest do
  use ExUnit.Case, async: false
  alias Druzhok.EmbeddingCache

  defp unique_instance, do: "test_ec_#{:rand.uniform(1_000_000_000)}"
  defp unique_hash, do: "hash_#{:rand.uniform(1_000_000_000)}"

  test "put and get round-trip" do
    instance = unique_instance()
    hash = unique_hash()

    entry = %{instance_name: instance, file: "MEMORY.md", chunk_hash: hash,
              chunk_text: "hello world", embedding: [1.0, 2.0, 3.0], model_name: "test-model"}
    assert :ok = EmbeddingCache.put(instance, entry)
    assert {:ok, [1.0, 2.0, 3.0]} = EmbeddingCache.get(instance, hash)
  end

  test "get returns :miss for unknown hash" do
    assert :miss = EmbeddingCache.get(unique_instance(), unique_hash())
  end

  test "delete_missing_files removes entries for absent files" do
    instance = unique_instance()
    keep_file = "keep_#{:rand.uniform(1_000_000)}.md"
    remove_file = "remove_#{:rand.uniform(1_000_000)}.md"

    for file <- [keep_file, remove_file] do
      hash = "hash_#{file}"
      EmbeddingCache.put(instance, %{instance_name: instance, file: file,
                                     chunk_hash: hash,
                                     chunk_text: "text", embedding: [1.0], model_name: "m"})
    end

    EmbeddingCache.delete_missing_files(instance, [keep_file])
    assert {:ok, _} = EmbeddingCache.get(instance, "hash_#{keep_file}")
    assert :miss = EmbeddingCache.get(instance, "hash_#{remove_file}")
  end

  test "put updates existing entry" do
    instance = unique_instance()
    hash = unique_hash()

    entry = %{instance_name: instance, file: "f.md", chunk_hash: hash,
              chunk_text: "v1", embedding: [1.0], model_name: "m"}
    EmbeddingCache.put(instance, entry)
    EmbeddingCache.put(instance, %{entry | embedding: [2.0], chunk_text: "v2"})
    assert {:ok, [2.0]} = EmbeddingCache.get(instance, hash)
  end
end
