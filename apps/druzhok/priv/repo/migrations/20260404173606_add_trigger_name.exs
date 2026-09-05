defmodule Druzhok.Repo.Migrations.AddTriggerName do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :trigger_name, :string
    end
  end
end
