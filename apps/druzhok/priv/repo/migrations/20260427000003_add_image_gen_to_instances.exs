defmodule Druzhok.Repo.Migrations.AddImageGenToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :image_gen_enabled, :boolean, default: false, null: false
      add :image_gen_model, :string
    end
  end
end
