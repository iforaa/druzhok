defmodule Druzhok.Repo.Migrations.CreateCrashLogs do
  use Ecto.Migration

  def change do
    create table(:crash_logs) do
      add :level, :string, null: false
      add :message, :text, null: false
      add :source, :string
      add :instance_name, :string

      timestamps(updated_at: false)
    end

    create index(:crash_logs, [:inserted_at])
    create index(:crash_logs, [:instance_name])
  end
end
