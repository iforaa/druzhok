defmodule PiCore.Memory.EmbeddingClient do
  @moduledoc """
  HTTP client for embedding APIs (Voyage AI, OpenAI-compatible).

  Voyage AI is the default provider (recommended by Anthropic).
  Configure: `%{embedding_api_url: "https://api.voyageai.com/v1", embedding_api_key: "...", embedding_model: "voyage-3.5"}`
  """

  def embed(text, opts) do
    case embed_batch([text], opts) do
      {:ok, [vec]} -> {:ok, vec}
      error -> error
    end
  end

  def embed_batch(texts, opts) when is_list(texts) do
    api_url = opts[:embedding_api_url]
    api_key = opts[:embedding_api_key]
    model = opts[:embedding_model]

    cond do
      is_nil(api_url) or api_url == "" ->
        {:error, "Embedding API URL not configured (set in Settings > Embeddings)"}
      is_nil(api_key) or api_key == "" ->
        {:error, "Embedding API key not configured (set in Settings > Embeddings)"}
      is_nil(model) or model == "" ->
        {:error, "Embedding model not configured (set in Settings > Embeddings)"}
      true ->
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

    case safe_request(url, headers, body) do
      {:ok, %{status: 200, body: resp}} ->
        parse_response(resp)

      {:ok, %{status: status, body: resp}} ->
        {:error, "Embedding API error #{status}: #{String.slice(resp, 0, 200)}"}

      {:error, reason} ->
        {:error, "Embedding request failed: #{inspect(reason)}"}
    end
  end

  defp safe_request(url, headers, body) do
    Finch.build(:post, url, headers, body)
    |> Finch.request(PiCore.Finch, receive_timeout: 30_000)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, reason}
  end

  defp parse_response(body) do
    case Jason.decode(body) do
      {:ok, %{"data" => data}} when is_list(data) ->
        vectors = data |> Enum.sort_by(& &1["index"]) |> Enum.map(& &1["embedding"])
        {:ok, vectors}

      {:ok, other} ->
        {:error, "Unexpected embedding response: #{inspect(Map.keys(other))}"}

      {:error, _} ->
        {:error, "Failed to parse embedding response"}
    end
  end
end
