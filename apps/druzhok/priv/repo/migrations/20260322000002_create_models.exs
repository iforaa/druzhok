defmodule Druzhok.Repo.Migrations.CreateModels do
  use Ecto.Migration

  def change do
    create table(:models) do
      add :model_id, :string, null: false
      add :label, :string, null: false
      add :position, :integer, default: 0

      timestamps()
    end

    create unique_index(:models, [:model_id])

    # Seed default models
    execute """
    INSERT INTO models (model_id, label, position, inserted_at, updated_at) VALUES
      ('Qwen/Qwen3.5-397B-A17B', 'Qwen 3.5 397B', 0, datetime('now'), datetime('now')),
      ('zai-org/GLM-5', 'GLM-5', 1, datetime('now'), datetime('now')),
      ('moonshotai/Kimi-K2.5-fast', 'Kimi K2.5', 2, datetime('now'), datetime('now')),
      ('meta-llama/Llama-3.3-70B-Instruct-fast', 'Llama 3.3 70B', 3, datetime('now'), datetime('now'))
    """, """
    DELETE FROM models WHERE model_id IN ('Qwen/Qwen3.5-397B-A17B', 'zai-org/GLM-5', 'moonshotai/Kimi-K2.5-fast', 'meta-llama/Llama-3.3-70B-Instruct-fast')
    """
  end
end
