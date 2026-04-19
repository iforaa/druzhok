defmodule Druzhok.Repo.Migrations.AddUsageLogsInstanceInsertedIndex do
  use Ecto.Migration

  def change do
    create index(:usage_logs, [:instance_id, :inserted_at])
  end
end
