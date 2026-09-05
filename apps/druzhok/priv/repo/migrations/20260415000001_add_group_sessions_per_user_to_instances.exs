defmodule Druzhok.Repo.Migrations.AddGroupSessionsPerUserToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :group_sessions_per_user, :boolean, default: true, null: false
    end
  end
end
