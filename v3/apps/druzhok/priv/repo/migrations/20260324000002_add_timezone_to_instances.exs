defmodule Druzhok.Repo.Migrations.AddTimezoneToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :timezone, :string, default: "UTC"
    end
  end
end
