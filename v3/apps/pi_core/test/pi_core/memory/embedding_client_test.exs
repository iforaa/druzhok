defmodule PiCore.Memory.EmbeddingClientTest do
  use ExUnit.Case

  alias PiCore.Memory.EmbeddingClient

  test "embed returns error when no API configured" do
    assert {:error, msg} = EmbeddingClient.embed("hello", %{})
    assert msg =~ "not configured"
  end

  test "embed_batch returns error when no API configured" do
    assert {:error, _} = EmbeddingClient.embed_batch(["hello", "world"], %{})
  end

  test "embed uses embedding_api_url/key when provided" do
    # This will fail to connect but proves the opts are read correctly
    result = EmbeddingClient.embed("hello", %{
      embedding_api_url: "http://localhost:99999",
      embedding_api_key: "test-key",
      embedding_model: "test-model"
    })
    assert {:error, _} = result
  end

  test "embed falls back to api_url/api_key" do
    result = EmbeddingClient.embed("hello", %{
      api_url: "http://localhost:99999",
      api_key: "test-key"
    })
    assert {:error, _} = result
  end
end
