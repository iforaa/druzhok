defmodule Druzhok.Repo.Migrations.AddMentionOnlyToInstances do
  use Ecto.Migration

  def change do
    # Column may already exist in production DBs (added manually before this migration)
    execute(
      "ALTER TABLE instances ADD COLUMN mention_only INTEGER DEFAULT 0",
      "SELECT 1"
    )
  rescue
    _ -> :ok
  end
end
