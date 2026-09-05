defmodule Druzhok.Repo.Migrations.CreateLlmRequests do
  use Ecto.Migration

  def change do
    create table(:llm_requests) do
      add :instance_name, :string
      add :chat_id, :integer
      add :model, :string
      add :input_tokens, :integer, default: 0
      add :output_tokens, :integer, default: 0
      add :tool_calls_count, :integer, default: 0
      add :elapsed_ms, :integer
      add :iteration, :integer, default: 0

      timestamps(updated_at: false)
    end

    create index(:llm_requests, [:instance_name, :inserted_at])
    create index(:llm_requests, [:inserted_at])
  end
end
