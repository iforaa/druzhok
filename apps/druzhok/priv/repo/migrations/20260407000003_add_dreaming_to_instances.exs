defmodule Druzhok.Repo.Migrations.AddDreamingToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :dreaming, :boolean, default: false
    end
  end
end
