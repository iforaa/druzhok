defmodule DruzhokWebWeb.EmbedController do
  @moduledoc """
  `POST /internal/embed {texts}`: the embedder ruoc-gateway routes
  `POST /v1/embeddings` to. Druzhok owns the model; ruoc owns the price and
  the ledger. No usage row here: the tenant-facing `/v1/embeddings` leg
  records the call.
  """

  use DruzhokWebWeb, :controller
  require Logger

  @max_texts 64
  @max_chars 8_000
  @model "multilingual-e5-small"

  def embed(conn, params) do
    started = System.monotonic_time(:millisecond)

    with {:ok, texts} <- validate(params["texts"]),
         {:ok, %{vectors: vectors, tokens: tokens}} <- embed_module().embed(texts) do
      log(200, started, tokens, length(texts))
      json(conn, %{vectors: vectors, tokens: tokens, dim: length(List.first(vectors) || []), model: @model})
    else
      {:error, :bad_request} -> reply(conn, 400, "bad_request", started)
      {:error, :too_many_texts} -> reply(conn, 413, "too_many_texts", started)
      {:error, :text_too_long} -> reply(conn, 413, "text_too_long", started)
      {:error, :worker_down} -> reply(conn, 503, "worker_down", started)
      {:error, :embed_failed} -> reply(conn, 502, "embed_failed", started)
    end
  end

  defp validate(texts) when is_list(texts) and texts != [] do
    cond do
      not Enum.all?(texts, &is_binary/1) -> {:error, :bad_request}
      length(texts) > @max_texts -> {:error, :too_many_texts}
      Enum.any?(texts, &(String.length(&1) > @max_chars)) -> {:error, :text_too_long}
      true -> {:ok, texts}
    end
  end

  defp validate(_), do: {:error, :bad_request}

  defp embed_module, do: Application.get_env(:druzhok_web, :embed_module, Druzhok.Embed.Worker)

  defp reply(conn, status, code, started) do
    log(status, started, 0, 0, code)
    conn |> put_status(status) |> json(%{error: code})
  end

  defp log(status, started, tokens, count, code \\ nil) do
    latency = System.monotonic_time(:millisecond) - started
    Logger.info("[embed] #{status}#{if code, do: " " <> code} #{count} texts #{tokens} tokens #{latency}ms")
  end
end
