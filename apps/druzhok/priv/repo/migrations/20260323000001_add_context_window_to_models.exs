defmodule Druzhok.Repo.Migrations.AddContextWindowToModels do
  use Ecto.Migration

  def change do
    alter table(:models) do
      add :context_window, :integer, default: 32_000
      add :supports_reasoning, :boolean, default: false
      add :supports_tools, :boolean, default: true
    end
  end
end
