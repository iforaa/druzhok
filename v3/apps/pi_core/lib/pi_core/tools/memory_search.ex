defmodule PiCore.Tools.MemorySearch do
  alias PiCore.Tools.Tool
  alias PiCore.Memory.Search

  def new(opts \\ %{}) do
    %Tool{
      name: "memory_search",
      description: "Search your memory files (MEMORY.md and daily notes in memory/) for relevant information. Uses both keyword matching and semantic similarity. Use this to recall facts, preferences, decisions, and context from previous conversations.",
      parameters: %{
        query: %{type: :string, description: "What to search for (natural language query)"}
      },
      execute: fn args, context -> execute(args, context, opts) end
    }
  end

  def execute(%{"query" => query}, %{workspace: workspace} = context, opts) do
    search_opts = Map.merge(opts, %{
      instance_name: context[:instance_name],
      embedding_cache: context[:embedding_cache]
    })

    case Search.search(workspace, query, search_opts) do
      {:ok, []} ->
        {:ok, "No relevant memories found for: #{query}"}

      {:ok, results} ->
        formatted = results
        |> Enum.map(fn r ->
          "📄 #{r.file}:#{r.start_line}-#{r.end_line} (score: #{Float.round(r.score, 2)})\n#{String.slice(r.text, 0, 500)}"
        end)
        |> Enum.join("\n\n---\n\n")
        {:ok, formatted}

      {:error, reason} ->
        {:error, "Memory search failed: #{reason}"}
    end
  end
end
