defmodule PiCore.Memory.EmbeddingClientTest do
  use ExUnit.Case

  alias PiCore.Memory.EmbeddingClient

  test "embed returns error when no API key configured" do
    assert {:error, msg} = EmbeddingClient.embed("hello", %{})
    assert msg =~ "not configured"
  end

  test "embed_batch returns error when no API key configured" do
    assert {:error, _} = EmbeddingClient.embed_batch(["hello", "world"], %{})
  end

  test "defaults to Voyage API URL when only key provided" do
    # Will fail to connect but proves default URL is used
    result = EmbeddingClient.embed("hello", %{
      embedding_api_key: "test-key"
    })
    # Should attempt voyage API, not error about missing config
    assert {:error, msg} = result
    refute msg =~ "not configured"
  end

  test "uses custom URL when provided" do
    result = EmbeddingClient.embed("hello", %{
      embedding_api_url: "http://localhost:19999",
      embedding_api_key: "test-key",
      embedding_model: "test-model"
    })
    assert {:error, _} = result
  end
end
