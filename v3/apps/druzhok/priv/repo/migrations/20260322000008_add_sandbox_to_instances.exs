defmodule Druzhok.Repo.Migrations.AddSandboxToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :sandbox, :string, default: "local"
    end
  end
end
