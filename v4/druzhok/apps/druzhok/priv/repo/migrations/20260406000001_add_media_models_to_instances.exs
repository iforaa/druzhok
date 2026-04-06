defmodule Druzhok.Repo.Migrations.AddMediaModelsToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :image_model, :string
      add :audio_model, :string
      add :embedding_model, :string
    end
  end
end
