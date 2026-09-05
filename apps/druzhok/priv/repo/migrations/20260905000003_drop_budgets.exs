defmodule Druzhok.Repo.Migrations.DropBudgets do
  use Ecto.Migration

  # Money lives in ruoc-gateway now: one account per bot, balance as the limit.
  # The per-bot daily USD cap and its spend counter have nothing to count.
  def up do
    drop_if_exists table(:budgets)

    alter table(:instances) do
      remove :daily_budget_cents
    end
  end

  def down do
    alter table(:instances) do
      add :daily_budget_cents, :integer, default: 0
    end

    create table(:budgets) do
      add :instance_id, references(:instances, on_delete: :delete_all)
      add :balance, :integer, default: 0
      add :lifetime_used, :integer, default: 0
      add :reset_at, :date
      timestamps()
    end

    create unique_index(:budgets, [:instance_id])
  end
end
