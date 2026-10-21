defmodule Druzhok.Repo.Migrations.AddTelegramUpdateWakes do
  use Ecto.Migration

  # Sleep/wake spec, "Waking only for addressed updates": false for a group
  # message the bot would not answer, so it does not wake a sleeping bot.
  def change do
    alter table(:telegram_updates) do
      add :wakes, :boolean, null: false, default: true
    end
  end
end
