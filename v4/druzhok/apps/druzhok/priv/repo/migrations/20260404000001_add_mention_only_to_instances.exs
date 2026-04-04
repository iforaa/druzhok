defmodule Druzhok.Repo.Migrations.AddMentionOnlyToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :mention_only, :boolean, default: false
    end
  end
end
