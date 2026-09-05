defmodule Druzhok.Repo.Migrations.AddProviderToModels do
  use Ecto.Migration

  def change do
    alter table(:models) do
      add :provider, :string, default: "openai"
    end

    # Update existing Nebius models
    execute "UPDATE models SET provider = 'openai'", "SELECT 1"

    # Add Claude models
    execute """
    INSERT INTO models (model_id, label, provider, position, inserted_at, updated_at) VALUES
      ('claude-sonnet-4-20250514', 'Claude Sonnet 4', 'anthropic', 10, datetime('now'), datetime('now')),
      ('claude-haiku-4-5-20251001', 'Claude Haiku 4.5', 'anthropic', 11, datetime('now'), datetime('now'))
    """, """
    DELETE FROM models WHERE provider = 'anthropic'
    """
  end
end
