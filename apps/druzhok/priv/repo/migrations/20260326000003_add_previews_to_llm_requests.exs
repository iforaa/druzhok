defmodule Druzhok.Repo.Migrations.AddPreviewsToLlmRequests do
  use Ecto.Migration

  def change do
    alter table(:llm_requests) do
      add :prompt_preview, :text
      add :response_preview, :text
    end
  end
end
