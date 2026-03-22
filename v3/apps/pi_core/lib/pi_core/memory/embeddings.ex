defmodule PiCore.Memory.Embeddings do
  @moduledoc "Get embeddings from an OpenAI-compatible API (via proxy or direct)."

  def get_embeddings(texts, opts) do
    url = "#{String.trim_trailing(opts.api_url, "/")}/embeddings"
    body = Jason.encode!(%{input: texts, model: opts[:model] || "text-embedding-3-small"})

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{opts.api_key}"},
      {"accept-encoding", "identity"}
    ]

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
  end

  def cosine_similarity(a, b) when is_list(a) and is_list(b) do
    {dot, norm_a, norm_b} = Enum.zip(a, b)
    |> Enum.reduce({0.0, 0.0, 0.0}, fn {ai, bi}, {dot, na, nb} ->
      {dot + ai * bi, na + ai * ai, nb + bi * bi}
    end)

    denom = :math.sqrt(norm_a) * :math.sqrt(norm_b)
    if denom == 0, do: 0.0, else: dot / denom
  end
end
