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
