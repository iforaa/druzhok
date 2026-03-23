defmodule PiCore.Memory.EmbeddingClient do
  @moduledoc """
  HTTP client for embedding APIs. Supports any OpenAI-compatible endpoint
  (Voyage AI, Nebius, OpenAI, etc).

  Configure via opts: %{api_url: "https://api.voyageai.com/v1", api_key: "...", model: "voyage-3.5"}
  """

  @default_model "voyage-3.5"

  @doc "Embed a single text."
  def embed(text, opts) do
    case embed_batch([text], opts) do
      {:ok, [vec]} -> {:ok, vec}
      error -> error
    end
  end

  @doc "Embed a list of texts."
  def embed_batch(texts, opts) when is_list(texts) do
    api_url = opts[:embedding_api_url] || opts[:api_url]
    api_key = opts[:embedding_api_key] || opts[:api_key]
    model = opts[:embedding_model] || @default_model

    if is_nil(api_url) or is_nil(api_key) do
      {:error, "Embedding API not configured (need embedding_api_url and embedding_api_key)"}
    else
      do_request(texts, api_url, api_key, model)
    end
  end

  defp do_request(texts, api_url, api_key, model) do
    url = "#{String.trim_trailing(api_url, "/")}/embeddings"
    body = Jason.encode!(%{input: texts, model: model})

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{api_key}"},
      {"accept-encoding", "identity"}
    ]

    try do
      case Finch.build(:post, url, headers, body) |> Finch.request(PiCore.Finch, receive_timeout: 30_000) do
        {:ok, %{status: 200, body: resp}} ->
          data = Jason.decode!(resp)
          vectors = data["data"] |> Enum.sort_by(& &1["index"]) |> Enum.map(& &1["embedding"])
          {:ok, vectors}

        {:ok, %{status: status, body: resp}} ->
          {:error, "Embedding API error #{status}: #{String.slice(resp, 0, 200)}"}

        {:error, reason} ->
          {:error, "Embedding request failed: #{inspect(reason)}"}
      end
    rescue
      e -> {:error, "Embedding request failed: #{Exception.message(e)}"}
    catch
      :exit, reason -> {:error, "Embedding request failed: #{inspect(reason)}"}
    end
  end
end
