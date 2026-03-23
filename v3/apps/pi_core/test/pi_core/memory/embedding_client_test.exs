defmodule PiCore.Memory.EmbeddingClientTest do
  use ExUnit.Case

  alias PiCore.Memory.EmbeddingClient

  test "embed returns error when no URL configured" do
    assert {:error, msg} = EmbeddingClient.embed("hello", %{embedding_api_key: "k", embedding_model: "m"})
    assert msg =~ "URL"
  end

  test "embed returns error when no key configured" do
    assert {:error, msg} = EmbeddingClient.embed("hello", %{embedding_api_url: "http://x", embedding_model: "m"})
    assert msg =~ "key"
  end

  test "embed returns error when no model configured" do
    assert {:error, msg} = EmbeddingClient.embed("hello", %{embedding_api_url: "http://x", embedding_api_key: "k"})
    assert msg =~ "model"
  end

  test "embed returns error for all empty opts" do
    assert {:error, _} = EmbeddingClient.embed("hello", %{})
  end

  test "attempts API call when fully configured" do
    result = EmbeddingClient.embed("hello", %{
      embedding_api_url: "http://localhost:19999",
      embedding_api_key: "test-key",
      embedding_model: "test-model"
    })
    assert {:error, msg} = result
    assert msg =~ "request failed"
  end
end
