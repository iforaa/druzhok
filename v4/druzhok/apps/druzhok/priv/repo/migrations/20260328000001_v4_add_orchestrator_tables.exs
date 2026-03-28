defmodule Druzhok.Repo.Migrations.V4AddOrchestratorTables do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :tenant_key, :string
      add :bot_runtime, :string, default: "zeroclaw"
    end

    create unique_index(:instances, [:tenant_key])

    create table(:tokens) do
      add :token, :string, null: false
      add :bot_username, :string
      add :instance_id, references(:instances, on_delete: :nilify_all)
      timestamps()
    end

    create unique_index(:tokens, [:token])
    create index(:tokens, [:instance_id])

    create table(:budgets) do
      add :instance_id, references(:instances, on_delete: :delete_all), null: false
      add :balance, :integer, null: false, default: 0
      add :lifetime_used, :integer, null: false, default: 0
      timestamps()
    end

    create unique_index(:budgets, [:instance_id])

    create table(:usage_logs) do
      add :instance_id, references(:instances, on_delete: :delete_all), null: false
      add :model, :string, null: false
      add :prompt_tokens, :integer, null: false
      add :completion_tokens, :integer, null: false
      add :total_tokens, :integer, null: false
      add :cost_cents, :integer, null: false, default: 0
      add :requested_model, :string
      add :resolved_model, :string
      add :provider, :string
      add :latency_ms, :integer
      timestamps(updated_at: false)
    end

    create index(:usage_logs, [:instance_id])
    create index(:usage_logs, [:inserted_at])
  end
end
