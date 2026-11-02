defmodule Druzhok.Repo.Migrations.AddGroupChats do
  use Ecto.Migration

  # CleoHub release spec, PR M. `group_chats`: the groups a bot has seen and what
  # its owner decided (`allowed_telegram_chats` means "answer without a mention",
  # something else). `group_rate_events`: the answered messages of the last hour,
  # so the group limits hold across a restart and a sleep.
  def change do
    create table(:group_chats) do
      add(:instance_id, references(:instances, on_delete: :delete_all), null: false)
      add(:chat_id, :bigint, null: false)
      add(:title, :string)
      add(:status, :string, null: false, default: "pending")
      add(:decided_by, :bigint)
      add(:notified_at, :utc_datetime_usec)
      add(:rate_notice_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:group_chats, [:instance_id, :chat_id]))

    create table(:group_rate_events) do
      add(:instance_id, references(:instances, on_delete: :delete_all), null: false)
      add(:chat_id, :bigint, null: false)
      add(:user_id, :bigint, null: false)
      add(:update_id, :bigint, null: false)
      add(:at, :bigint, null: false)
    end

    create(unique_index(:group_rate_events, [:instance_id, :update_id]))
    create(index(:group_rate_events, [:instance_id, :chat_id, :at]))
    create(index(:group_rate_events, [:at]))
  end
end
