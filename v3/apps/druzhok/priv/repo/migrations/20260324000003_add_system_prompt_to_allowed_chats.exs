defmodule Druzhok.Repo.Migrations.AddSystemPromptToAllowedChats do
  use Ecto.Migration

  def change do
    alter table(:allowed_chats) do
      add :system_prompt, :text
    end
  end
end
