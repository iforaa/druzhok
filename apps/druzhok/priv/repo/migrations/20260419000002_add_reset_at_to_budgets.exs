defmodule Druzhok.Repo.Migrations.AddResetAtToBudgets do
  use Ecto.Migration

  def change do
    alter table(:budgets) do
      add :reset_at, :date
    end
  end
end
