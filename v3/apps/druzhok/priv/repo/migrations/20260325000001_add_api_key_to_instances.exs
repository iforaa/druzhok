defmodule Druzhok.Repo.Migrations.AddApiKeyToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :api_key, :string
    end

    create unique_index(:instances, [:api_key])
  end
end
