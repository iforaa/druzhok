defmodule Druzhok.Repo.Migrations.CreateInstances do
  use Ecto.Migration

  def change do
    create table(:instances) do
      add :name, :string, null: false
      add :telegram_token, :string, null: false
      add :model, :string, null: false
      add :workspace, :string, null: false
      add :active, :boolean, default: true, null: false

      timestamps()
    end

    create unique_index(:instances, [:name])
  end
end
