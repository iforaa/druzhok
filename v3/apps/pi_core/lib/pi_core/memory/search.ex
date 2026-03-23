defmodule PiCore.Memory.Search do
  @moduledoc """
  Hybrid memory search: BM25 keyword + vector similarity.
  Searches MEMORY.md and memory/*.md files.
  """

  alias PiCore.Memory.{Chunker, BM25, VectorMath, EmbeddingClient}

  defmodule Result do
    defstruct [:text, :file, :start_line, :end_line, :score]
  end

  @vector_weight 0.7
  @text_weight 0.3
  @max_results 6

  def search(workspace, query, opts \\ %{}) do
    files = list_memory_files(workspace)
    if files == [], do: {:ok, []}, else: do_search(files, workspace, query, opts)
  end

  defp do_search(files, workspace, query, opts) do
    # Chunk all memory files
    chunks = Enum.flat_map(files, fn file ->
      path = Path.join(workspace, file)
      case File.read(path) do
        {:ok, content} -> Chunker.chunk_file(content, file)
        _ -> []
      end
    end)

    if chunks == [] do
      {:ok, []}
    else
      # BM25 keyword search
      bm25_docs = chunks |> Enum.with_index() |> Enum.map(fn {c, i} -> {i, c.text} end)
      bm25_results = BM25.search(bm25_docs, query)
      bm25_scores = Map.new(bm25_results)

      # Normalize BM25 scores to 0..1
      max_bm25 = case bm25_results do
        [] -> 1.0
        list -> list |> Enum.map(&elem(&1, 1)) |> Enum.max() |> max(0.001)
      end

      # Try vector search if API is available
      vector_scores = case get_vector_scores(chunks, query, opts) do
        {:ok, scores} -> scores
        {:error, _} -> %{}
      end

      # Merge scores
      results = chunks
      |> Enum.with_index()
      |> Enum.map(fn {chunk, i} ->
        bm25_score = Map.get(bm25_scores, i, 0.0) / max_bm25
        vector_score = Map.get(vector_scores, i, 0.0)

        final_score = if map_size(vector_scores) > 0 do
          @vector_weight * vector_score + @text_weight * bm25_score
        else
          bm25_score
        end

        %Result{
          text: chunk.text,
          file: chunk.file,
          start_line: chunk.start_line,
          end_line: chunk.end_line,
          score: final_score
        }
      end)
      |> Enum.filter(& &1.score > 0.01)
      |> Enum.sort_by(& -&1.score)
      |> Enum.take(opts[:max_results] || @max_results)

      {:ok, results}
    end
  end

  defp get_vector_scores(chunks, query, opts) do
    instance_name = opts[:instance_name]
    cache_mod = opts[:embedding_cache]

    case EmbeddingClient.embed(query, opts) do
      {:ok, query_vec} ->
        chunk_vecs = get_chunk_vectors(chunks, instance_name, cache_mod, opts)

        scores = chunk_vecs
        |> Enum.with_index()
        |> Map.new(fn {vec, i} ->
          score = if vec, do: VectorMath.cosine_similarity(query_vec, vec), else: 0.0
          {i, score}
        end)

        # Cleanup stale cache entries after search
        if cache_mod && instance_name do
          current_files = chunks |> Enum.map(& &1.file) |> Enum.uniq()
          cache_mod.delete_missing_files(instance_name, current_files)
        end

        {:ok, scores}

      {:error, _reason} ->
        {:error, "Embeddings unavailable"}
    end
  end

  defp get_chunk_vectors(chunks, instance_name, cache_mod, opts) do
    # Split into cached and uncached, preserving original index
    indexed = Enum.with_index(chunks)

    {cached_entries, uncached_entries} =
      Enum.split_with(indexed, fn {chunk, _idx} ->
        if cache_mod && instance_name do
          cache_mod.get(instance_name, VectorMath.chunk_hash(chunk.text)) != :miss
        else
          false
        end
      end)

    # Load cached vectors
    cached_map = Map.new(cached_entries, fn {chunk, idx} ->
      {:ok, vec} = cache_mod.get(instance_name, VectorMath.chunk_hash(chunk.text))
      {idx, vec}
    end)

    # Batch embed all uncached chunks in one API call
    uncached_map = if uncached_entries == [] do
      %{}
    else
      texts = Enum.map(uncached_entries, fn {chunk, _} -> chunk.text end)
      case EmbeddingClient.embed_batch(texts, opts) do
        {:ok, vectors} ->
          Enum.zip(uncached_entries, vectors)
          |> Map.new(fn {{chunk, idx}, vec} ->
            # Cache the new embedding
            if cache_mod && instance_name do
              cache_mod.put(instance_name, %{
                file: chunk.file,
                chunk_hash: VectorMath.chunk_hash(chunk.text),
                chunk_text: String.slice(chunk.text, 0, 500),
                embedding: vec
              })
            end
            {idx, vec}
          end)
        {:error, _} ->
          Map.new(uncached_entries, fn {_, idx} -> {idx, nil} end)
      end
    end

    # Reassemble in original order
    all_vecs = Map.merge(cached_map, uncached_map)
    Enum.map(0..(length(chunks) - 1), fn idx -> Map.get(all_vecs, idx) end)
  end

  defp list_memory_files(workspace) do
    files = []

    memory_md = "MEMORY.md"
    files = if File.exists?(Path.join(workspace, memory_md)), do: [memory_md | files], else: files

    memory_dir = Path.join(workspace, "memory")
    files = if File.dir?(memory_dir) do
      daily = File.ls!(memory_dir)
      |> Enum.filter(&String.ends_with?(&1, ".md"))
      |> Enum.map(&"memory/#{&1}")
      files ++ daily
    else
      files
    end

    files
  end
end
