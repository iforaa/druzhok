defmodule Druzhok.Repo.Migrations.AddOnDemandModelToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :on_demand_model, :string
    end
  end
end
