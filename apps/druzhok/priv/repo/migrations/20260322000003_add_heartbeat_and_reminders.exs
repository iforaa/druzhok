defmodule Druzhok.Repo.Migrations.AddHeartbeatAndReminders do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :heartbeat_interval, :integer, default: 0  # minutes, 0 = disabled
    end

    create table(:reminders) do
      add :instance_name, :string, null: false
      add :fire_at, :utc_datetime, null: false
      add :message, :string, null: false
      add :fired, :boolean, default: false

      timestamps()
    end

    create index(:reminders, [:instance_name])
    create index(:reminders, [:fire_at])
  end
end
