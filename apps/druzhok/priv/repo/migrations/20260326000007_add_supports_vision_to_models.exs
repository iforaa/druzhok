defmodule Druzhok.Repo.Migrations.AddSupportsVisionToModels do
  use Ecto.Migration

  def change do
    alter table(:models) do
      add :supports_vision, :boolean, default: false
    end

    # Mark known vision-capable models
    execute "UPDATE models SET supports_vision = 1 WHERE model_id LIKE 'claude%' OR model_id LIKE 'google/%' OR model_id LIKE '%vision%' OR model_id LIKE '%image%'"
  end
end
