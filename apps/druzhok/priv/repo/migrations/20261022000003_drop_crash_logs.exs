defmodule Druzhok.Repo.Migrations.DropCrashLogs do
  use Ecto.Migration

  # Errors only the dashboard read (dashboard removal spec, step 3); they stay
  # in the journal.
  def up do
    drop_if_exists table(:crash_logs)
  end

  def down do
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
