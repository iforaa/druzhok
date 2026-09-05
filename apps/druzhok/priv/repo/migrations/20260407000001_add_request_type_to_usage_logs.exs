defmodule Druzhok.Repo.Migrations.AddRequestTypeToUsageLogs do
  use Ecto.Migration

  def change do
    alter table(:usage_logs) do
      add :request_type, :string, default: "chat"
      add :audio_duration_ms, :integer
    end
  end
end
