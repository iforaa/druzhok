defmodule Druzhok.Repo.Migrations.AddRuocToInstances do
  use Ecto.Migration

  # A bot with a ruoc key is served through ruoc-gateway; one without keeps
  # the legacy OpenRouter path until it is migrated.
  def change do
    alter table(:instances) do
      add :ruoc_account_id, :string
      add :ruoc_api_key, :string
    end
  end
end
