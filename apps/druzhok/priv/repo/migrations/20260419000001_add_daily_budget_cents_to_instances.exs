defmodule Druzhok.Repo.Migrations.AddDailyBudgetCentsToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :daily_budget_cents, :integer, null: false, default: 0
    end
  end
end
