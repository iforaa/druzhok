defmodule PiCore.Memory.BM25 do
  @moduledoc "BM25 keyword scoring for memory search."

  @k1 1.5
  @b 0.75

  def search(docs, query) when is_list(docs) do
    query_tokens = tokenize(query)
    if query_tokens == [] || docs == [], do: [], else: do_search(docs, query_tokens)
  end

  defp do_search(docs, query_tokens) do
    tokenized = Enum.map(docs, fn {id, text} ->
      tokens = tokenize(text)
      {id, tokens, length(tokens)}
    end)

    avg_len = if tokenized == [], do: 0,
      else: Enum.reduce(tokenized, 0, fn {_, _, len}, acc -> acc + len end) / length(tokenized)

    n = length(tokenized)

    # Document frequency
    df = Enum.reduce(tokenized, %{}, fn {_, tokens, _}, acc ->
      tokens |> MapSet.new() |> Enum.reduce(acc, fn token, a ->
        Map.update(a, token, 1, & &1 + 1)
      end)
    end)

    tokenized
    |> Enum.map(fn {id, tokens, doc_len} ->
      tf = Enum.frequencies(tokens)
      score = Enum.reduce(query_tokens, 0.0, fn term, acc ->
        term_freq = Map.get(tf, term, 0)
        if term_freq == 0, do: acc, else: acc + bm25_score(term_freq, doc_len, avg_len, Map.get(df, term, 0), n)
      end)
      {id, score}
    end)
    |> Enum.filter(fn {_, score} -> score > 0 end)
    |> Enum.sort_by(fn {_, score} -> -score end)
  end

  defp bm25_score(tf, doc_len, avg_len, doc_freq, n) do
    idf = :math.log((n - doc_freq + 0.5) / (doc_freq + 0.5) + 1)
    numerator = tf * (@k1 + 1)
    denominator = tf + @k1 * (1 - @b + @b * (doc_len / max(avg_len, 1)))
    idf * (numerator / denominator)
  end

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.split(~r/\W+/)
    |> Enum.filter(& &1 != "")
  end
end
