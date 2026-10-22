defmodule Druzhok.Repo.Migrations.AddDeleteFailures do
  use Ecto.Migration

  # Partner access spec (ruoc-gateway docs/superpowers/specs/
  # 2026-10-22-partner-access-design.md), "Suspend on delete": a delete whose
  # ruoc suspend failed keeps the row and is retried on the start backoff
  # curve, recorded like start_*.
  def change do
    alter table(:instances) do
      add :delete_error, :string
      add :delete_failed_at, :utc_datetime_usec
      add :delete_failures, :integer, null: false, default: 0
    end
  end
end
