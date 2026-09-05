defmodule Druzhok.Repo.Migrations.AddInstanceMessages do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :reject_message, :string
      add :welcome_message, :string
    end
  end
end
