defmodule Druzhok.Repo.Migrations.MakeTelegramTokenNullable do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE instances_new (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      telegram_token TEXT,
      model TEXT NOT NULL,
      workspace TEXT NOT NULL,
      active INTEGER DEFAULT true NOT NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      heartbeat_interval INTEGER DEFAULT 0,
      owner_telegram_id INTEGER,
      sandbox TEXT DEFAULT 'local',
      timezone TEXT DEFAULT 'UTC',
      api_key TEXT
    )
    """
    execute "INSERT INTO instances_new SELECT * FROM instances"
    execute "DROP TABLE instances"
    execute "ALTER TABLE instances_new RENAME TO instances"
    execute ~s|CREATE UNIQUE INDEX "instances_name_index" ON "instances" ("name")|
    execute ~s|CREATE UNIQUE INDEX "instances_api_key_index" ON "instances" ("api_key")|
  end

  def down do
    :ok
  end
end
