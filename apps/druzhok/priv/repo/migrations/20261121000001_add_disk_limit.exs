defmodule Druzhok.Repo.Migrations.AddDiskLimit do
  use Ecto.Migration

  # Per-bot disk limit (spec 2026-11-21-bot-disk-limit-design.md): the
  # operator's override, the warning state `Druzhok.DiskCheck` keeps, and what
  # its last check read. All null until set or read.
  def change do
    alter table(:instances) do
      add(:disk_mb, :integer)
      add(:disk_warned, :string)
      add(:disk_operator_alerted_at, :utc_datetime_usec)
      add(:disk_used_kb, :integer)
      add(:disk_limit_kb, :integer)
      add(:disk_files, :integer)
      add(:disk_file_limit, :integer)
      add(:disk_checked_at, :utc_datetime)
    end
  end
end
