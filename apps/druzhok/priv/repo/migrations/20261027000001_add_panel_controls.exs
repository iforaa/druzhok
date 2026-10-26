defmodule Druzhok.Repo.Migrations.AddPanelControls do
  use Ecto.Migration

  # Spec 2026-10-26-panel-controls-design.md: settings saved in the panel wait
  # for a quiet moment (settings_seq > settings_applied_seq), and a delete
  # started in the panel waits for the owner's tap in the superbot.
  def change do
    alter table(:instances) do
      add(:settings_seq, :integer, default: 0, null: false)
      add(:settings_applied_seq, :integer, default: 0, null: false)
      add(:settings_saved_at, :utc_datetime_usec)
      add(:delete_confirm_token, :string)
      add(:delete_confirm_expires_at, :utc_datetime)
    end
  end
end
