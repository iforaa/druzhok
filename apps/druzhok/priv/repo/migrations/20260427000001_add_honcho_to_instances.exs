defmodule Druzhok.Repo.Migrations.AddHonchoToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :memory_provider, :string, default: "builtin", null: false
      add :honcho_workspace, :string
      add :honcho_token, :text
    end
  end
end
