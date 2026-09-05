defmodule Druzhok.Repo.Migrations.AddChatIdToReminders do
  use Ecto.Migration

  def change do
    alter table(:reminders) do
      add :chat_id, :bigint
    end
  end
end
