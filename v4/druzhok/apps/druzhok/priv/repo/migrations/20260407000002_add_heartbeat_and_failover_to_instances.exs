defmodule Druzhok.Repo.Migrations.AddHeartbeatAndFailoverToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :heartbeat_active_start, :string
      add :heartbeat_active_end, :string
      add :heartbeat_target, :string
      add :fallback_models, :string
    end
  end
end
