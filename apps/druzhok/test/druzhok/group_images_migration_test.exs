Code.require_file(
  "../../priv/repo/migrations/20261126000001_add_group_images_enabled.exs",
  __DIR__
)

defmodule Druzhok.GroupImagesMigrationTest do
  use ExUnit.Case, async: false

  defmodule MigrationRepo do
    use Ecto.Repo, otp_app: :druzhok, adapter: Ecto.Adapters.SQLite3
  end

  @tag :tmp_dir
  test "every bot gets group pictures on; bots with pictures on are queued for a quiet restart",
       %{tmp_dir: tmp_dir} do
    start_supervised!({MigrationRepo, database: Path.join(tmp_dir, "migration.db"), pool_size: 2})

    MigrationRepo.query!("""
    CREATE TABLE instances (
      id INTEGER PRIMARY KEY, image_gen_enabled INTEGER NOT NULL,
      settings_seq INTEGER NOT NULL, settings_saved_at TEXT
    )
    """)

    MigrationRepo.query!("INSERT INTO instances VALUES (1, 1, 3, NULL), (2, 0, 3, NULL)")

    assert :ok =
             Ecto.Migrator.up(
               MigrationRepo,
               20_261_126_000_001,
               Druzhok.Repo.Migrations.AddGroupImagesEnabled,
               log: false
             )

    assert %{rows: [[1, 1, 4, saved], [2, 1, 3, nil]]} =
             MigrationRepo.query!(
               "SELECT id, group_images_enabled, settings_seq, settings_saved_at FROM instances ORDER BY id"
             )

    assert is_binary(saved)

    MigrationRepo.query!(
      "INSERT INTO instances (id, image_gen_enabled, settings_seq) VALUES (3, 0, 0)"
    )

    assert %{rows: [[1]]} =
             MigrationRepo.query!("SELECT group_images_enabled FROM instances WHERE id = 3")
  end
end
