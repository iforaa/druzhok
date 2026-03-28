defmodule Druzhok.Repo.Migrations.AddDreamHourToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :dream_hour, :integer, default: -1
    end
  end
end
