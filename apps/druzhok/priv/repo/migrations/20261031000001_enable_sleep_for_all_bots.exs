defmodule Druzhok.Repo.Migrations.EnableSleepForAllBots do
  use Ecto.Migration

  # Sleep is on by default now. New rows get it from the schema default (bots
  # are inserted through %Instance{}). The column default stays false on
  # purpose: SQLite cannot alter a default, and rebuilding `instances` could
  # cascade-delete queued updates.
  def up do
    execute("UPDATE instances SET sleep_enabled = 1")
  end

  # Who had opted in before is not recorded. exqlite refuses an empty
  # statement, so this cannot be `execute(up, "")`.
  def down, do: :ok
end
