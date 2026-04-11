defmodule Druzhok.Repo.Migrations.DropPools do
  use Ecto.Migration

  def up do
    # Unbind any instances that were still referencing the pool, so we can
    # drop the FK safely on SQLite (which drops/recreates the table on
    # alter table).
    execute "UPDATE instances SET pool_id = NULL"

    # SQLite requires indexes referencing a dropped column to be gone first.
    drop_if_exists index(:instances, [:pool_id])

    alter table(:instances) do
      remove :pool_id
    end

    drop_if_exists table(:pools)
  end

  def down do
    create table(:pools) do
      add :name, :string, null: false
      add :container, :string, null: false
      add :port, :integer, null: false
      add :max_tenants, :integer, default: 10
      add :status, :string, default: "starting"

      timestamps()
    end

    create unique_index(:pools, [:name])

    alter table(:instances) do
      add :pool_id, references(:pools, on_delete: :nilify_all)
    end
  end
end
