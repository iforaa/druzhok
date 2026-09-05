defmodule Druzhok.Repo.Migrations.SeedMimoReasoning do
  use Ecto.Migration

  def up do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    execute("""
    INSERT OR IGNORE INTO models
      (model_id, label, position, provider, context_window,
       supports_reasoning, supports_tools, supports_vision,
       inserted_at, updated_at)
    VALUES
      ('xiaomi/mimo-v2-pro', 'MiMo V2 Pro (reasoning)', 100, 'openrouter',
       131072, 1, 1, 0, '#{now}', '#{now}')
    """)
  end

  def down do
    execute("DELETE FROM models WHERE model_id = 'xiaomi/mimo-v2-pro'")
  end
end
