defmodule Druzhok.Repo.Migrations.DropDashboardTables do
  use Ecto.Migration

  # Dashboard logins, gone with the dashboard
  # (docs/superpowers/specs/2026-10-21-dashboard-removal-design.md, step 3).
  def up do
    drop_if_exists table(:users)
  end

  def down do
    create table(:users) do
      add :email, :string, null: false
      add :password_hash, :string, null: false
      add :role, :string, null: false, default: "user"
      timestamps()
    end

    create unique_index(:users, [:email])
  end
end
