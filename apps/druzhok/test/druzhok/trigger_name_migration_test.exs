Code.require_file(
  "../../priv/repo/migrations/20261110000001_seed_group_trigger_names.exs",
  __DIR__
)

defmodule Druzhok.TriggerNameMigrationTest do
  use ExUnit.Case, async: false

  defmodule MigrationRepo do
    use Ecto.Repo, otp_app: :druzhok, adapter: Ecto.Adapters.SQLite3
  end

  @tag :tmp_dir
  test "backfill uses graphemes, preserves existing triggers and changes only settings metadata",
       %{tmp_dir: tmp_dir} do
    start_supervised!({MigrationRepo, database: Path.join(tmp_dir, "migration.db"), pool_size: 2})

    MigrationRepo.query!("""
    CREATE TABLE instances (
      id INTEGER PRIMARY KEY, display_name TEXT, trigger_name TEXT,
      settings_seq INTEGER NOT NULL, settings_saved_at TEXT,
      settings_applied_seq INTEGER NOT NULL, marker TEXT
    )
    """)

    cases = [
      {" Друг! ", nil, "Друг!"},
      {"C++", "", "C++"},
      {String.duplicate("e\u0301", 17), nil, String.duplicate("e\u0301", 17)},
      {String.duplicate("e\u0301", 32), nil, String.duplicate("e\u0301", 32)},
      {String.duplicate("e\u0301", 33), nil, nil},
      {"\u2003Друг\u2003", nil, "Друг"},
      {"  ", "", ""},
      {nil, nil, nil},
      {"Вася", "Друг", "Друг"}
    ]

    for {{display, trigger, _expected}, id} <- Enum.with_index(cases) do
      MigrationRepo.query!("INSERT INTO instances VALUES (?, ?, ?, 7, NULL, 4, 'unchanged')", [
        id,
        display,
        trigger
      ])
    end

    assert :ok =
             Ecto.Migrator.up(
               MigrationRepo,
               20_261_110_000_001,
               Druzhok.Repo.Migrations.SeedGroupTriggerNames,
               log: false
             )

    for {{display, trigger, expected}, id} <- Enum.with_index(cases) do
      assert %{rows: [[^display, ^expected, seq, saved, 4, "unchanged"]]} =
               MigrationRepo.query!(
                 "SELECT display_name, trigger_name, settings_seq, settings_saved_at, settings_applied_seq, marker FROM instances WHERE id = ?",
                 [id]
               )

      changed = trigger != expected
      assert seq == if(changed, do: 8, else: 7)
      assert is_binary(saved) == changed
    end
  end
end
