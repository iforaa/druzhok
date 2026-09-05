defmodule Druzhok.Repo.Migrations.AddWebsiteHostingEnabledToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :website_hosting_enabled, :boolean, default: false, null: false
    end
  end
end
