defmodule Druzhok.Repo.Migrations.AddTelegramWebhookRelay do
  use Ecto.Migration

  # Telegram webhook relay (docs/superpowers/specs/2026-10-20-telegram-webhook-relay-design.md).
  # Every bot stays in polling mode until it is switched one at a time. The
  # relay pause lives on the row, not in a process, so a one-off
  # `ops/druzhok-run.sh` BEAM (BotManager.restart) can pause and resume the
  # relay running inside druzhok.service.
  def change do
    alter table(:instances) do
      add(:telegram_mode, :string, null: false, default: "polling")
      add(:telegram_webhook_secret, :string)
      add(:telegram_relay_paused_until, :utc_datetime)
      add(:telegram_relay_pause_reason, :string)
    end

    create table(:telegram_updates) do
      add(:instance_id, references(:instances, on_delete: :delete_all), null: false)
      add(:update_id, :integer, null: false)
      add(:payload, :text, null: false)
      add(:received_at, :utc_datetime_usec, null: false)
      # The bot answered 2xx (or the row was dropped); null = pending.
      add(:acked_at, :utc_datetime_usec)
      add(:attempts, :integer, null: false, default: 0)
      add(:last_error, :string)
      # null | "expired" | "rejected"
      add(:dropped_reason, :string)
    end

    create(unique_index(:telegram_updates, [:instance_id, :update_id]))
    create(index(:telegram_updates, [:instance_id, :acked_at, :update_id]))
  end
end
