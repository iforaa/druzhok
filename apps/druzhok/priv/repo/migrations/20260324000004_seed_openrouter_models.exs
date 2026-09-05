defmodule Druzhok.Repo.Migrations.SeedOpenrouterModels do
  use Ecto.Migration

  def up do
    execute """
    INSERT INTO models (model_id, label, provider, context_window, supports_tools, supports_reasoning, position, inserted_at, updated_at) VALUES
      ('google/gemini-2.0-flash-lite-001', 'Gemini 2.0 Flash Lite', 'openrouter', 1048576, true, false, 20, datetime('now'), datetime('now')),
      ('google/gemini-2.5-flash-image', 'Gemini 2.5 Flash Image', 'openrouter', 1048576, false, false, 21, datetime('now'), datetime('now')),
      ('google/gemini-2.5-flash', 'Gemini 2.5 Flash', 'openrouter', 1048576, true, true, 22, datetime('now'), datetime('now'))
    """
  end

  def down do
    execute "DELETE FROM models WHERE provider = 'openrouter'"
  end
end
