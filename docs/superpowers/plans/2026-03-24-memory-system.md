# Memory System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add local embeddings via Bumblebee, SQLite embedding cache, memory writing tools, and pre-compaction memory flush to Druzhok v3.

**Architecture:** An `Nx.Serving` process runs `all-MiniLM-L6-v2` for local embeddings. A `memory_embeddings` SQLite table caches chunk vectors keyed by SHA256 hash. `memory_write` tool and pre-compaction flush write to daily `memory/YYYY-MM-DD.md` files.

**Tech Stack:** Elixir/OTP, Bumblebee, Nx (BinaryBackend), Ecto/SQLite, ExUnit

**Spec:** `docs/superpowers/specs/2026-03-24-memory-system-design.md`

---

## File Structure

### New files (pi_core)
- `v3/apps/pi_core/lib/pi_core/memory/embedding_server.ex` — Nx.Serving wrapper for local embeddings
- `v3/apps/pi_core/lib/pi_core/memory/embedding_cache.ex` — behaviour definition
- `v3/apps/pi_core/lib/pi_core/memory/vector_math.ex` — cosine_similarity extracted from Embeddings
- `v3/apps/pi_core/lib/pi_core/memory/flush.ex` — pre-compaction memory flush logic
- `v3/apps/pi_core/lib/pi_core/tools/memory_write.ex` — memory_write tool
- `v3/apps/pi_core/test/pi_core/memory/embedding_server_test.exs`
- `v3/apps/pi_core/test/pi_core/memory/vector_math_test.exs`
- `v3/apps/pi_core/test/pi_core/memory/flush_test.exs`
- `v3/apps/pi_core/test/pi_core/tools/memory_write_test.exs`

### New files (druzhok)
- `v3/apps/druzhok/lib/druzhok/embedding_cache.ex` — DB-backed cache implementation
- `v3/apps/druzhok/priv/repo/migrations/20260324000001_create_memory_embeddings.exs`
- `v3/apps/druzhok/priv/repo/migrations/20260324000002_add_timezone_to_instances.exs`
- `v3/apps/druzhok/test/druzhok/embedding_cache_test.exs`

### Modified files
- `v3/apps/pi_core/mix.exs` — add bumblebee, nx deps
- `v3/apps/pi_core/lib/pi_core/application.ex` — add Nx.Serving to supervision tree
- `v3/apps/pi_core/lib/pi_core/memory/search.ex` — use EmbeddingServer + cache
- `v3/apps/pi_core/lib/pi_core/memory/embeddings.ex` — remove (replaced by EmbeddingServer)
- `v3/apps/pi_core/lib/pi_core/compaction.ex` — add memory flush before compaction
- `v3/apps/pi_core/lib/pi_core/session.ex` — add timezone, pass flush opts to compaction, add memory_write tool
- `v3/apps/pi_core/lib/pi_core/tools/memory_search.ex` — pass instance_name and cache to Search
- `v3/apps/druzhok/lib/druzhok/instance.ex` — add timezone field
- `v3/apps/druzhok/lib/druzhok/instance/sup.ex` — pass timezone and embedding_cache in config

---

### Task 1: VectorMath + Dependencies

**Files:**
- Modify: `v3/apps/pi_core/mix.exs`
- Create: `v3/apps/pi_core/lib/pi_core/memory/vector_math.ex`
- Create: `v3/apps/pi_core/test/pi_core/memory/vector_math_test.exs`

- [ ] **Step 1: Add deps to mix.exs**

In `v3/apps/pi_core/mix.exs`, add to `deps`:
```elixir
{:bumblebee, "~> 0.6"},
{:nx, "~> 0.9"}
```

- [ ] **Step 2: Install deps**

Run: `cd v3 && mix deps.get`

- [ ] **Step 3: Write VectorMath tests**

```elixir
# v3/apps/pi_core/test/pi_core/memory/vector_math_test.exs
defmodule PiCore.Memory.VectorMathTest do
  use ExUnit.Case

  alias PiCore.Memory.VectorMath

  test "cosine_similarity of identical vectors is 1.0" do
    v = [1.0, 2.0, 3.0]
    assert_in_delta VectorMath.cosine_similarity(v, v), 1.0, 0.001
  end

  test "cosine_similarity of orthogonal vectors is 0.0" do
    a = [1.0, 0.0, 0.0]
    b = [0.0, 1.0, 0.0]
    assert_in_delta VectorMath.cosine_similarity(a, b), 0.0, 0.001
  end

  test "cosine_similarity of opposite vectors is -1.0" do
    a = [1.0, 0.0]
    b = [-1.0, 0.0]
    assert_in_delta VectorMath.cosine_similarity(a, b), -1.0, 0.001
  end

  test "cosine_similarity returns 0.0 for zero vectors" do
    assert VectorMath.cosine_similarity([0.0, 0.0], [1.0, 1.0]) == 0.0
  end

  test "chunk_hash returns consistent SHA256" do
    hash1 = VectorMath.chunk_hash("hello world")
    hash2 = VectorMath.chunk_hash("hello world")
    assert hash1 == hash2
    assert byte_size(hash1) == 64  # hex-encoded SHA256
  end

  test "chunk_hash differs for different content" do
    assert VectorMath.chunk_hash("hello") != VectorMath.chunk_hash("world")
  end
end
```

- [ ] **Step 4: Write VectorMath implementation**

```elixir
# v3/apps/pi_core/lib/pi_core/memory/vector_math.ex
defmodule PiCore.Memory.VectorMath do
  @moduledoc "Vector operations for embedding similarity search."

  def cosine_similarity(a, b) when is_list(a) and is_list(b) do
    {dot, norm_a, norm_b} = Enum.zip(a, b)
    |> Enum.reduce({0.0, 0.0, 0.0}, fn {ai, bi}, {dot, na, nb} ->
      {dot + ai * bi, na + ai * ai, nb + bi * bi}
    end)

    denom = :math.sqrt(norm_a) * :math.sqrt(norm_b)
    if denom == 0, do: 0.0, else: dot / denom
  end

  def chunk_hash(text) when is_binary(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end
end
```

- [ ] **Step 5: Run tests**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/memory/vector_math_test.exs`

- [ ] **Step 6: Commit**

Message: `add VectorMath and bumblebee/nx dependencies`

---

### Task 2: EmbeddingServer (local Bumblebee inference)

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/memory/embedding_server.ex`
- Create: `v3/apps/pi_core/test/pi_core/memory/embedding_server_test.exs`
- Modify: `v3/apps/pi_core/lib/pi_core/application.ex`

- [ ] **Step 1: Write tests**

```elixir
# v3/apps/pi_core/test/pi_core/memory/embedding_server_test.exs
defmodule PiCore.Memory.EmbeddingServerTest do
  use ExUnit.Case

  alias PiCore.Memory.EmbeddingServer

  # These tests require the model to be downloaded (~80MB first time)
  # Skip in CI with @tag :slow

  @tag :slow
  test "embed returns a 384-dim vector" do
    case EmbeddingServer.embed("Hello world") do
      {:ok, vector} ->
        assert is_list(vector)
        assert length(vector) == 384
        assert Enum.all?(vector, &is_float/1)
      {:error, :model_unavailable} ->
        # Model not downloaded — acceptable in test env
        :ok
    end
  end

  @tag :slow
  test "embed_batch returns vectors for each input" do
    case EmbeddingServer.embed_batch(["hello", "world", "test"]) do
      {:ok, vectors} ->
        assert length(vectors) == 3
        assert Enum.all?(vectors, fn v -> length(v) == 384 end)
      {:error, :model_unavailable} ->
        :ok
    end
  end

  @tag :slow
  test "similar texts have higher similarity than dissimilar" do
    with {:ok, v1} <- EmbeddingServer.embed("The cat sat on the mat"),
         {:ok, v2} <- EmbeddingServer.embed("A cat was sitting on a rug"),
         {:ok, v3} <- EmbeddingServer.embed("Quantum physics equations") do
      sim_similar = PiCore.Memory.VectorMath.cosine_similarity(v1, v2)
      sim_different = PiCore.Memory.VectorMath.cosine_similarity(v1, v3)
      assert sim_similar > sim_different
    end
  end

  test "embed returns error when serving not started" do
    # If the serving process isn't running (e.g., model failed to load),
    # calling embed should return an error, not crash
    result = EmbeddingServer.embed("test")
    assert match?({:ok, _} | {:error, _}, result)
  end
end
```

- [ ] **Step 2: Write implementation**

```elixir
# v3/apps/pi_core/lib/pi_core/memory/embedding_server.ex
defmodule PiCore.Memory.EmbeddingServer do
  @moduledoc """
  Local embedding inference via Bumblebee + Nx.Serving.
  Loads all-MiniLM-L6-v2 (384-dim) at startup.
  """

  require Logger

  @serving_name PiCore.Memory.EmbeddingServing
  @model_repo "sentence-transformers/all-MiniLM-L6-v2"

  def child_spec(_opts) do
    case build_serving() do
      {:ok, serving} ->
        %{
          id: __MODULE__,
          start: {Nx.Serving, :start_link, [[serving: serving, name: @serving_name, batch_timeout: 50]]},
          type: :worker,
          restart: :permanent
        }
      {:error, reason} ->
        Logger.warning("EmbeddingServer: model unavailable (#{reason}), starting in degraded mode")
        # Start a dummy process that just stays alive
        %{
          id: __MODULE__,
          start: {Agent, :start_link, [fn -> :degraded end, [name: @serving_name]]},
          type: :worker,
          restart: :permanent
        }
    end
  end

  def embed(text) do
    embed_batch([text])
    |> case do
      {:ok, [vec]} -> {:ok, vec}
      error -> error
    end
  end

  def embed_batch(texts) when is_list(texts) do
    try do
      results = Nx.Serving.batched_run(@serving_name, texts)
      vectors = results
      |> Map.get(:embeddings, results)
      |> Nx.to_list()
      {:ok, vectors}
    rescue
      _ -> {:error, :model_unavailable}
    catch
      :exit, _ -> {:error, :model_unavailable}
    end
  end

  defp build_serving do
    try do
      {:ok, model} = Bumblebee.load_model({:hf, @model_repo})
      {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, @model_repo})

      serving = Bumblebee.Text.TextEmbedding.text_embedding(model, tokenizer,
        compile: [batch_size: 32, sequence_length: 128],
        defn_options: [compiler: EXLA]
      )

      {:ok, serving}
    rescue
      e ->
        {:error, Exception.message(e)}
    end
  end
end
```

**Note for implementer**: The `Bumblebee.Text.TextEmbedding.text_embedding/3` function and its exact API may differ by Bumblebee version. Check `mix docs` or the Bumblebee README. If `TextEmbedding` doesn't exist, use `Bumblebee.Text.text_embedding/3` directly. The key is: load model + tokenizer, create a serving, return vectors. Also: if EXLA is not available (we're using BinaryBackend), remove `compiler: EXLA` from `defn_options` or set it to `Nx.Defn.Evaluator`. **Read the Bumblebee docs before implementing** — the API evolves. The code above is a starting point, not gospel.

- [ ] **Step 3: Add to supervision tree**

In `v3/apps/pi_core/lib/pi_core/application.ex`, add to children:
```elixir
PiCore.Memory.EmbeddingServer
```

- [ ] **Step 4: Run tests**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/memory/embedding_server_test.exs --include slow`

Note: First run will download ~80MB model. May take a minute.

- [ ] **Step 5: Commit**

Message: `add local embedding server via Bumblebee`

---

### Task 3: EmbeddingCache behaviour + DB implementation

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/memory/embedding_cache.ex`
- Create: `v3/apps/druzhok/lib/druzhok/embedding_cache.ex`
- Create: `v3/apps/druzhok/priv/repo/migrations/20260324000001_create_memory_embeddings.exs`
- Create: `v3/apps/druzhok/test/druzhok/embedding_cache_test.exs`

- [ ] **Step 1: Create behaviour**

```elixir
# v3/apps/pi_core/lib/pi_core/memory/embedding_cache.ex
defmodule PiCore.Memory.EmbeddingCache do
  @moduledoc """
  Behaviour for embedding vector cache.
  Implementation lives in druzhok app (DB-backed).
  """

  @callback get(instance_name :: String.t(), chunk_hash :: String.t()) :: {:ok, [float()]} | :miss
  @callback put(instance_name :: String.t(), entry :: map()) :: :ok
  @callback delete_missing_files(instance_name :: String.t(), current_files :: [String.t()]) :: :ok
end
```

- [ ] **Step 2: Create migration**

```elixir
# v3/apps/druzhok/priv/repo/migrations/20260324000001_create_memory_embeddings.exs
defmodule Druzhok.Repo.Migrations.CreateMemoryEmbeddings do
  use Ecto.Migration

  def change do
    create table(:memory_embeddings) do
      add :instance_name, :string, null: false
      add :file, :string, null: false
      add :chunk_hash, :string, null: false
      add :chunk_text, :text
      add :embedding, :binary, null: false
      add :model_name, :string, default: "all-MiniLM-L6-v2"

      timestamps()
    end

    create unique_index(:memory_embeddings, [:instance_name, :chunk_hash])
    create index(:memory_embeddings, [:instance_name, :file])
  end
end
```

- [ ] **Step 3: Run migration**

Run: `cd v3 && mix ecto.migrate`

- [ ] **Step 4: Write tests**

```elixir
# v3/apps/druzhok/test/druzhok/embedding_cache_test.exs
defmodule Druzhok.EmbeddingCacheTest do
  use ExUnit.Case

  alias Druzhok.EmbeddingCache

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Druzhok.Repo)
    :ok
  end

  test "put and get round-trip" do
    entry = %{
      instance_name: "test",
      file: "MEMORY.md",
      chunk_hash: "abc123",
      chunk_text: "hello world",
      embedding: [1.0, 2.0, 3.0],
      model_name: "test-model"
    }
    assert :ok = EmbeddingCache.put("test", entry)
    assert {:ok, [1.0, 2.0, 3.0]} = EmbeddingCache.get("test", "abc123")
  end

  test "get returns :miss for unknown hash" do
    assert :miss = EmbeddingCache.get("test", "nonexistent")
  end

  test "delete_missing_files removes entries for absent files" do
    for file <- ["keep.md", "remove.md"] do
      EmbeddingCache.put("test", %{
        instance_name: "test", file: file, chunk_hash: "hash_#{file}",
        chunk_text: "text", embedding: [1.0], model_name: "m"
      })
    end

    EmbeddingCache.delete_missing_files("test", ["keep.md"])

    assert {:ok, _} = EmbeddingCache.get("test", "hash_keep.md")
    assert :miss = EmbeddingCache.get("test", "hash_remove.md")
  end

  test "put updates existing entry" do
    entry = %{instance_name: "test", file: "f.md", chunk_hash: "h1",
              chunk_text: "v1", embedding: [1.0], model_name: "m"}
    EmbeddingCache.put("test", entry)
    EmbeddingCache.put("test", %{entry | embedding: [2.0], chunk_text: "v2"})
    assert {:ok, [2.0]} = EmbeddingCache.get("test", "h1")
  end
end
```

- [ ] **Step 5: Write implementation**

```elixir
# v3/apps/druzhok/lib/druzhok/embedding_cache.ex
defmodule Druzhok.EmbeddingCache do
  @behaviour PiCore.Memory.EmbeddingCache

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  schema "memory_embeddings" do
    field :instance_name, :string
    field :file, :string
    field :chunk_hash, :string
    field :chunk_text, :string
    field :embedding, :binary
    field :model_name, :string

    timestamps()
  end

  @impl true
  def get(instance_name, chunk_hash) do
    case Druzhok.Repo.get_by(__MODULE__, instance_name: instance_name, chunk_hash: chunk_hash) do
      nil -> :miss
      entry -> {:ok, :erlang.binary_to_term(entry.embedding)}
    end
  end

  @impl true
  def put(instance_name, entry) do
    existing = Druzhok.Repo.get_by(__MODULE__, instance_name: instance_name, chunk_hash: entry.chunk_hash)
    record = existing || %__MODULE__{}

    record
    |> changeset(%{
      instance_name: instance_name,
      file: entry.file,
      chunk_hash: entry.chunk_hash,
      chunk_text: entry.chunk_text,
      embedding: :erlang.term_to_binary(entry.embedding),
      model_name: entry[:model_name] || "all-MiniLM-L6-v2"
    })
    |> Druzhok.Repo.insert_or_update()

    :ok
  end

  @impl true
  def delete_missing_files(instance_name, current_files) do
    from(e in __MODULE__,
      where: e.instance_name == ^instance_name and e.file not in ^current_files
    )
    |> Druzhok.Repo.delete_all()

    :ok
  end

  defp changeset(record, attrs) do
    record
    |> cast(attrs, [:instance_name, :file, :chunk_hash, :chunk_text, :embedding, :model_name])
    |> validate_required([:instance_name, :file, :chunk_hash, :embedding])
    |> unique_constraint([:instance_name, :chunk_hash])
  end
end
```

- [ ] **Step 6: Run tests**

Run: `cd v3 && mix test apps/druzhok/test/druzhok/embedding_cache_test.exs`

- [ ] **Step 7: Commit**

Message: `add EmbeddingCache behaviour and SQLite implementation`

---

### Task 4: Rewrite Search to use local embeddings + cache

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/memory/search.ex`
- Modify: `v3/apps/pi_core/lib/pi_core/tools/memory_search.ex`
- Delete: `v3/apps/pi_core/lib/pi_core/memory/embeddings.ex`

- [ ] **Step 1: Rewrite Search.search/3**

Read current `v3/apps/pi_core/lib/pi_core/memory/search.ex`. Replace `get_vector_scores` with cache-aware local embedding flow:

```elixir
defp get_vector_scores(chunks, query, opts) do
  instance_name = opts[:instance_name]
  cache_mod = opts[:embedding_cache]

  case PiCore.Memory.EmbeddingServer.embed(query) do
    {:ok, query_vec} ->
      chunk_vecs = get_chunk_vectors(chunks, instance_name, cache_mod)

      scores = chunk_vecs
      |> Enum.with_index()
      |> Map.new(fn {vec, i} ->
        score = if vec, do: VectorMath.cosine_similarity(query_vec, vec), else: 0.0
        {i, score}
      end)

      # Cleanup stale cache entries
      if cache_mod && instance_name do
        current_files = chunks |> Enum.map(& &1.file) |> Enum.uniq()
        cache_mod.delete_missing_files(instance_name, current_files)
      end

      {:ok, scores}

    {:error, _reason} ->
      {:error, "Embeddings unavailable"}
  end
end

defp get_chunk_vectors(chunks, instance_name, cache_mod) do
  Enum.map(chunks, fn chunk ->
    hash = VectorMath.chunk_hash(chunk.text)

    # Try cache first
    cached = if cache_mod && instance_name do
      case cache_mod.get(instance_name, hash) do
        {:ok, vec} -> vec
        :miss -> nil
      end
    end

    if cached do
      cached
    else
      # Compute and cache
      case PiCore.Memory.EmbeddingServer.embed(chunk.text) do
        {:ok, vec} ->
          if cache_mod && instance_name do
            cache_mod.put(instance_name, %{
              file: chunk.file,
              chunk_hash: hash,
              chunk_text: String.slice(chunk.text, 0, 500),
              embedding: vec
            })
          end
          vec
        {:error, _} -> nil
      end
    end
  end)
end
```

Replace `alias PiCore.Memory.{Chunker, BM25, Embeddings}` with `alias PiCore.Memory.{Chunker, BM25, VectorMath, EmbeddingServer}` and remove the `Embeddings` reference.

- [ ] **Step 2: Update MemorySearch tool to pass instance_name and cache**

In `v3/apps/pi_core/lib/pi_core/tools/memory_search.ex`, update `execute`:

```elixir
def execute(%{"query" => query}, %{workspace: workspace} = context, opts) do
  search_opts = Map.merge(opts, %{
    instance_name: context[:instance_name],
    embedding_cache: context[:embedding_cache]
  })

  case Search.search(workspace, query, search_opts) do
    # ... rest unchanged
  end
end
```

- [ ] **Step 3: Delete old Embeddings module**

Remove `v3/apps/pi_core/lib/pi_core/memory/embeddings.ex` — its only function (`cosine_similarity`) now lives in `VectorMath`, and API embedding calls are replaced by `EmbeddingServer`.

- [ ] **Step 4: Run tests**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/memory/search_test.exs`

If search tests reference `Embeddings` directly, update them.

Also run: `cd v3 && mix test apps/pi_core/test/`

- [ ] **Step 5: Commit**

Message: `rewrite memory search to use local embeddings and cache`

---

### Task 5: memory_write tool

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/tools/memory_write.ex`
- Create: `v3/apps/pi_core/test/pi_core/tools/memory_write_test.exs`

- [ ] **Step 1: Write tests**

```elixir
# v3/apps/pi_core/test/pi_core/tools/memory_write_test.exs
defmodule PiCore.Tools.MemoryWriteTest do
  use ExUnit.Case

  alias PiCore.Tools.MemoryWrite

  @workspace System.tmp_dir!() |> Path.join("memory_write_test_#{:rand.uniform(99999)}")

  setup do
    File.mkdir_p!(Path.join(@workspace, "memory"))
    on_exit(fn -> File.rm_rf!(@workspace) end)
    :ok
  end

  test "writes to daily file by default" do
    tool = MemoryWrite.new()
    context = %{workspace: @workspace, timezone: "UTC"}
    {:ok, result} = tool.execute.(%{"content" => "User likes cats"}, context)

    today = Date.utc_today() |> Date.to_string()
    path = Path.join(@workspace, "memory/#{today}.md")
    assert File.exists?(path)
    content = File.read!(path)
    assert content =~ "User likes cats"
    assert content =~ "###"
    assert result =~ "Saved"
  end

  test "appends to existing file" do
    tool = MemoryWrite.new()
    context = %{workspace: @workspace, timezone: "UTC"}
    tool.execute.(%{"content" => "Fact one"}, context)
    tool.execute.(%{"content" => "Fact two"}, context)

    today = Date.utc_today() |> Date.to_string()
    path = Path.join(@workspace, "memory/#{today}.md")
    content = File.read!(path)
    assert content =~ "Fact one"
    assert content =~ "Fact two"
  end

  test "rejects writes outside memory/ directory" do
    tool = MemoryWrite.new()
    context = %{workspace: @workspace, timezone: "UTC"}
    {:error, msg} = tool.execute.(%{"content" => "hack", "file" => "AGENTS.md"}, context)
    assert msg =~ "memory/"
  end

  test "rejects path traversal" do
    tool = MemoryWrite.new()
    context = %{workspace: @workspace, timezone: "UTC"}
    {:error, _} = tool.execute.(%{"content" => "hack", "file" => "../../../etc/passwd"}, context)
  end

  test "writes to custom file within memory/" do
    tool = MemoryWrite.new()
    context = %{workspace: @workspace, timezone: "UTC"}
    {:ok, _} = tool.execute.(%{"content" => "Custom note", "file" => "memory/project.md"}, context)

    path = Path.join(@workspace, "memory/project.md")
    assert File.exists?(path)
    assert File.read!(path) =~ "Custom note"
  end
end
```

- [ ] **Step 2: Write implementation**

```elixir
# v3/apps/pi_core/lib/pi_core/tools/memory_write.ex
defmodule PiCore.Tools.MemoryWrite do
  alias PiCore.Tools.Tool

  def new(_opts \\ %{}) do
    %Tool{
      name: "memory_write",
      description: "Save a fact, preference, decision, or important context to memory. Written to daily memory file (memory/YYYY-MM-DD.md) by default. Use when the user says 'remember this' or when you learn something worth preserving.",
      parameters: %{
        content: %{type: :string, description: "What to remember (concise, factual)"},
        file: %{type: :string, description: "Target file (optional, defaults to today's daily file). Must be within memory/ directory."}
      },
      execute: fn args, context -> execute(args, context) end
    }
  end

  def execute(%{"content" => content} = args, context) do
    workspace = context[:workspace]
    timezone = context[:timezone] || "UTC"
    file = args["file"] || default_daily_file(timezone)

    # Path guard: must be within memory/
    unless String.starts_with?(file, "memory/") do
      {:error, "Writes must be within memory/ directory. Got: #{file}"}
    else
      full_path = Path.join(workspace, file)
      resolved = Path.expand(full_path)
      workspace_resolved = Path.expand(workspace)

      unless String.starts_with?(resolved, workspace_resolved) do
        {:error, "Path traversal detected"}
      else
        File.mkdir_p!(Path.dirname(full_path))
        timestamp = now_in_timezone(timezone)
        entry = "\n### #{timestamp}\n\n#{content}\n"
        File.write!(full_path, entry, [:append])
        {:ok, "Saved to #{file}"}
      end
    end
  end

  defp default_daily_file(timezone) do
    date = today_in_timezone(timezone)
    "memory/#{date}.md"
  end

  defp today_in_timezone("UTC"), do: Date.utc_today() |> Date.to_string()
  defp today_in_timezone(tz) do
    case DateTime.now(tz) do
      {:ok, dt} -> dt |> DateTime.to_date() |> Date.to_string()
      {:error, _} -> Date.utc_today() |> Date.to_string()
    end
  end

  defp now_in_timezone("UTC") do
    DateTime.utc_now() |> Calendar.strftime("%H:%M")
  end
  defp now_in_timezone(tz) do
    case DateTime.now(tz) do
      {:ok, dt} -> Calendar.strftime(dt, "%H:%M")
      {:error, _} -> DateTime.utc_now() |> Calendar.strftime("%H:%M")
    end
  end
end
```

- [ ] **Step 3: Run tests**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/tools/memory_write_test.exs`

- [ ] **Step 4: Commit**

Message: `add memory_write tool with path guard`

---

### Task 6: Pre-compaction memory flush

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/memory/flush.ex`
- Create: `v3/apps/pi_core/test/pi_core/memory/flush_test.exs`
- Modify: `v3/apps/pi_core/lib/pi_core/compaction.ex`

- [ ] **Step 1: Write Flush tests**

```elixir
# v3/apps/pi_core/test/pi_core/memory/flush_test.exs
defmodule PiCore.Memory.FlushTest do
  use ExUnit.Case

  alias PiCore.Memory.Flush
  alias PiCore.Loop.Message

  @workspace System.tmp_dir!() |> Path.join("flush_test_#{:rand.uniform(99999)}")

  setup do
    File.mkdir_p!(Path.join(@workspace, "memory"))
    on_exit(fn -> File.rm_rf!(@workspace) end)
    :ok
  end

  test "flush writes extracted context to daily memory file" do
    messages = [
      %Message{role: "user", content: "My name is Igor and I work at Acme Corp", timestamp: 1},
      %Message{role: "assistant", content: "Nice to meet you Igor!", timestamp: 2},
      %Message{role: "user", content: "Remember I prefer dark mode", timestamp: 3},
      %Message{role: "assistant", content: "Got it, dark mode preference noted", timestamp: 4},
    ]

    mock_llm = fn _opts ->
      {:ok, %PiCore.LLM.Client.Result{
        content: "- User name: Igor, works at Acme Corp\n- Prefers dark mode",
        tool_calls: []
      }}
    end

    :ok = Flush.flush(messages, mock_llm, @workspace, "UTC")

    today = Date.utc_today() |> Date.to_string()
    path = Path.join(@workspace, "memory/#{today}.md")
    assert File.exists?(path)
    content = File.read!(path)
    assert content =~ "Igor"
    assert content =~ "dark mode"
    assert content =~ "###"
  end

  test "flush does nothing when llm_fn is nil" do
    messages = [%Message{role: "user", content: "test", timestamp: 1}]
    assert :ok = Flush.flush(messages, nil, @workspace, "UTC")
  end

  test "flush handles LLM error gracefully" do
    messages = [%Message{role: "user", content: "test", timestamp: 1}]
    mock_llm = fn _opts -> {:error, "API down"} end
    assert :ok = Flush.flush(messages, mock_llm, @workspace, "UTC")
  end
end
```

- [ ] **Step 2: Write Flush implementation**

```elixir
# v3/apps/pi_core/lib/pi_core/memory/flush.ex
defmodule PiCore.Memory.Flush do
  @moduledoc """
  Pre-compaction memory flush: extract important context from
  messages about to be discarded and save to daily memory file.
  """

  require Logger

  def flush(_messages, nil, _workspace, _timezone), do: :ok
  def flush([], _llm_fn, _workspace, _timezone), do: :ok

  def flush(messages, llm_fn, workspace, timezone) do
    conversation = messages
    |> Enum.map(fn msg ->
      if msg.content, do: "[#{msg.role}]: #{String.slice(msg.content, 0, 1000)}", else: nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")

    prompt = """
    Extract important facts, decisions, user preferences, and context worth remembering from this conversation.
    Be concise — bullet points preferred. Only extract durable information, not transient details.

    <conversation>
    #{conversation}
    </conversation>
    """

    case llm_fn.(%{
      system_prompt: "You extract and summarize important facts from conversations. Be concise and factual.",
      messages: [%{role: "user", content: prompt}],
      tools: [],
      on_delta: nil
    }) do
      {:ok, result} when result.content != nil and result.content != "" ->
        write_to_daily_file(result.content, workspace, timezone)
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("Memory flush failed: #{inspect(reason)}")
        :ok
    end
  end

  defp write_to_daily_file(content, workspace, timezone) do
    date = today_in_timezone(timezone)
    time = now_in_timezone(timezone)
    file = Path.join(workspace, "memory/#{date}.md")
    File.mkdir_p!(Path.dirname(file))
    entry = "\n### #{time} (auto-flush)\n\n#{content}\n"
    File.write!(file, entry, [:append])
    :ok
  end

  defp today_in_timezone("UTC"), do: Date.utc_today() |> Date.to_string()
  defp today_in_timezone(tz) do
    case DateTime.now(tz) do
      {:ok, dt} -> dt |> DateTime.to_date() |> Date.to_string()
      _ -> Date.utc_today() |> Date.to_string()
    end
  end

  defp now_in_timezone("UTC"), do: DateTime.utc_now() |> Calendar.strftime("%H:%M")
  defp now_in_timezone(tz) do
    case DateTime.now(tz) do
      {:ok, dt} -> Calendar.strftime(dt, "%H:%M")
      _ -> DateTime.utc_now() |> Calendar.strftime("%H:%M")
    end
  end
end
```

- [ ] **Step 3: Wire flush into Compaction**

In `v3/apps/pi_core/lib/pi_core/compaction.ex`, update the `compact/3` function. After `{old, recent} = split_keeping_turns(...)`, before generating the summary, add:

```elixir
# Memory flush: save important context before discarding
if opts[:memory_flush] && opts[:workspace] do
  PiCore.Memory.Flush.flush(old_without_summary, opts[:llm_fn], opts[:workspace], opts[:timezone] || "UTC")
end
```

This requires passing `opts` into `compact` — change `compact(messages, budget, llm_fn)` to `compact(messages, budget, opts)` and extract `llm_fn` from `opts[:llm_fn]` inside.

- [ ] **Step 4: Run tests**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/memory/flush_test.exs`
Run: `cd v3 && mix test apps/pi_core/test/pi_core/compaction_test.exs`

- [ ] **Step 5: Commit**

Message: `add pre-compaction memory flush`

---

### Task 7: Wire into Session + Instance

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/session.ex`
- Modify: `v3/apps/druzhok/lib/druzhok/instance.ex`
- Modify: `v3/apps/druzhok/lib/druzhok/instance/sup.ex`
- Create: `v3/apps/druzhok/priv/repo/migrations/20260324000002_add_timezone_to_instances.exs`

- [ ] **Step 1: Create timezone migration**

```elixir
defmodule Druzhok.Repo.Migrations.AddTimezoneToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :timezone, :string, default: "UTC"
    end
  end
end
```

Run: `cd v3 && mix ecto.migrate`

- [ ] **Step 2: Update Instance schema**

In `v3/apps/druzhok/lib/druzhok/instance.ex`, add to schema:
```elixir
field :timezone, :string, default: "UTC"
```

Update changeset cast list to include `:timezone`.

- [ ] **Step 3: Update Session struct and compaction opts**

In `v3/apps/pi_core/lib/pi_core/session.ex`:

Add `:timezone` to the struct.

In `init/1`, read timezone: `timezone: opts[:timezone] || "UTC"`

Add `PiCore.Tools.MemoryWrite.new()` to `default_tools/0`.

Update `run_prompt/2` compaction opts:
```elixir
compaction_opts = if state.budget do
  %{
    budget: state.budget,
    llm_fn: llm_fn,
    workspace: state.workspace,
    timezone: state.timezone,
    memory_flush: true
  }
else
  %{llm_fn: llm_fn, max_messages: PiCore.Config.compaction_max_messages(),
    keep_recent: PiCore.Config.compaction_keep_recent()}
end
```

- [ ] **Step 4: Update Instance.Sup to pass timezone and embedding_cache**

In `v3/apps/druzhok/lib/druzhok/instance/sup.ex`, add to the persistent_term config:
```elixir
timezone: config[:timezone] || "UTC",
extra_tool_context: %{
  send_file_fn: send_file_fn,
  sandbox: sandbox_fns,
  embedding_cache: Druzhok.EmbeddingCache
},
```

- [ ] **Step 5: Run full test suite**

Run: `cd v3 && mix test`

- [ ] **Step 6: Commit**

Message: `wire memory system into Session and Instance`

---

### Task 8: Full test run and cleanup

- [ ] **Step 1: Run full test suite**

Run: `cd v3 && mix test`

- [ ] **Step 2: Check for compiler warnings**

Run: `cd v3 && mix compile --warnings-as-errors 2>&1 | grep "warning:" | grep -v "apps/data\|Reminder\|catch.*rescue\|unused.*data\|never match"`

- [ ] **Step 3: Fix any issues**

- [ ] **Step 4: Commit if needed**

Message: `fix warnings from memory system implementation`
