defmodule Druzhok.Repo.Migrations.CreatePools do
  use Ecto.Migration

  def change do
    create table(:pools) do
      add :name, :string, null: false
      add :container, :string, null: false
      add :port, :integer, null: false
      add :max_tenants, :integer, null: false, default: 10
      add :status, :string, null: false, default: "stopped"

      timestamps()
    end

    create unique_index(:pools, [:name])
    create unique_index(:pools, [:container])
    create unique_index(:pools, [:port])

    alter table(:instances) do
      add :pool_id, references(:pools, on_delete: :nilify_all)
    end

    create index(:instances, [:pool_id])
  end
end
