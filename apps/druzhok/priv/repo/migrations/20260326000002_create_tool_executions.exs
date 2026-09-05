defmodule Druzhok.Repo.Migrations.CreateToolExecutions do
  use Ecto.Migration

  def change do
    create table(:tool_executions) do
      add :instance_name, :string
      add :tool_name, :string
      add :elapsed_ms, :integer
      add :is_error, :boolean, default: false
      add :output_size, :integer, default: 0

      timestamps(updated_at: false)
    end

    create index(:tool_executions, [:instance_name, :inserted_at])
    create index(:tool_executions, [:tool_name, :inserted_at])
  end
end
