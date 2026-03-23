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
    ) |> Druzhok.Repo.delete_all()

    :ok
  end

  defp changeset(record, attrs) do
    record
    |> cast(attrs, [:instance_name, :file, :chunk_hash, :chunk_text, :embedding, :model_name])
    |> validate_required([:instance_name, :file, :chunk_hash, :embedding])
    |> unique_constraint([:instance_name, :chunk_hash])
  end
end
