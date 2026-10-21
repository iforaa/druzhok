defmodule Druzhok.Repo.Migrations.AddBotLifecycle do
  use Ecto.Migration

  # docs/superpowers/specs/2026-10-20-sleep-wake-design.md, "Model": what is
  # wanted (anyone writes) next to what the lifecycle controller did (only it
  # writes). Both seqs start at 0, so the controller's first pass restarts no
  # running bot; started_mode is the mode every bot last started in.
  def change do
    alter table(:instances) do
      add :start_seq, :integer, null: false, default: 0
      add :stop_seq, :integer, null: false, default: 0
      add :delete_requested, :boolean, null: false, default: false
      add :sleep_enabled, :boolean, null: false, default: false
      add :sleeping, :boolean, null: false, default: false
      add :applied_seq, :integer, null: false, default: 0
      add :stopped_seq, :integer, null: false, default: 0
      add :failed_seq, :integer, null: false, default: 0
      add :started_at, :utc_datetime
      add :started_mode, :string
      add :woke_at, :utc_datetime
      add :start_error, :string
      add :start_failed_at, :utc_datetime_usec
      add :start_failures, :integer, null: false, default: 0
    end

    execute "UPDATE instances SET started_mode = telegram_mode", ""
  end
end
