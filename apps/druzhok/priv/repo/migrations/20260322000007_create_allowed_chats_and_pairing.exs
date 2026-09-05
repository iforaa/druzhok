defmodule Druzhok.Repo.Migrations.CreateAllowedChatsAndPairing do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :owner_telegram_id, :bigint
    end

    create table(:allowed_chats) do
      add :instance_name, :string, null: false
      add :chat_id, :bigint, null: false
      add :chat_type, :string, null: false
      add :title, :string
      add :telegram_user_id, :bigint
      add :status, :string, null: false, default: "pending"
      add :info_sent, :boolean, default: false
      timestamps()
    end

    create unique_index(:allowed_chats, [:instance_name, :chat_id])

    create table(:pairing_codes) do
      add :instance_name, :string, null: false
      add :code, :string, null: false
      add :telegram_user_id, :bigint, null: false
      add :username, :string
      add :display_name, :string
      add :expires_at, :utc_datetime, null: false
      timestamps()
    end

    create unique_index(:pairing_codes, [:instance_name])
  end
end
