defmodule Druzhok.Repo.Migrations.AddGroupSharedMemoryToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :group_shared_memory, :boolean, default: false, null: false
    end
  end
end
