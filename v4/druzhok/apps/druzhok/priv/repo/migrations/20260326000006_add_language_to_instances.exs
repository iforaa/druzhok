defmodule Druzhok.Repo.Migrations.AddLanguageToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :language, :string, default: "ru"
    end
  end
end
