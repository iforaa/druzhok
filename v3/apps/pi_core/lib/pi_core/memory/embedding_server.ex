defmodule PiCore.Memory.EmbeddingServer do
  @moduledoc """
  Local embedding server using Bumblebee + Nx.Serving for
  sentence-transformers/all-MiniLM-L6-v2.

  Starts as part of the supervision tree. If the model fails to load
  (e.g. no network on first run), falls back to degraded mode where
  all calls return `{:error, :model_unavailable}`.
  """

  require Logger

  @serving_name PiCore.Memory.EmbeddingServing
  @model_repo "sentence-transformers/all-MiniLM-L6-v2"

  def child_spec(_opts) do
    case build_serving() do
      {:ok, serving} ->
        %{
          id: __MODULE__,
          start:
            {Nx.Serving, :start_link,
             [[serving: serving, name: @serving_name, batch_timeout: 50]]}
        }

      {:error, reason} ->
        Logger.warning("EmbeddingServer: model unavailable (#{inspect(reason)}), starting degraded")

        %{
          id: __MODULE__,
          start: {Agent, :start_link, [fn -> :degraded end, [name: @serving_name]]}
        }
    end
  end

  @doc "Embed a single text, returns `{:ok, [float]}` or `{:error, reason}`."
  def embed(text) when is_binary(text) do
    case embed_batch([text]) do
      {:ok, [vec]} -> {:ok, vec}
      error -> error
    end
  end

  @doc "Embed a list of texts, returns `{:ok, [[float]]}` or `{:error, reason}`."
  def embed_batch(texts) when is_list(texts) do
    try do
      results = Nx.Serving.batched_run(@serving_name, texts)
      vectors = extract_vectors(results)
      {:ok, vectors}
    rescue
      e -> {:error, {:inference_error, Exception.message(e)}}
    catch
      :exit, _ -> {:error, :model_unavailable}
    end
  end

  @doc "Returns the registered serving name."
  def serving_name, do: @serving_name

  # -- Private ---------------------------------------------------------------

  defp build_serving do
    {:ok, model_info} = Bumblebee.load_model({:hf, @model_repo})
    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, @model_repo})

    serving =
      Bumblebee.Text.TextEmbedding.text_embedding(model_info, tokenizer,
        output_attribute: :hidden_state,
        output_pool: :mean_pooling,
        embedding_processor: :l2_norm
      )

    {:ok, serving}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp extract_vectors(results) when is_list(results) do
    Enum.map(results, fn %{embedding: tensor} -> Nx.to_flat_list(tensor) end)
  end

  defp extract_vectors(%{embedding: tensor}) do
    [Nx.to_flat_list(tensor)]
  end
end
