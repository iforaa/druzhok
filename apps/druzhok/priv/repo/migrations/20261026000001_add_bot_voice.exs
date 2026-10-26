defmodule Druzhok.Repo.Migrations.AddBotVoice do
  use Ecto.Migration

  # Spec 2026-10-25-bot-voice-design.md: the bot's Telegram name, and what
  # druzhok last wrote to SOUL.md and AGENTS.md (the bot may edit both).
  def change do
    alter table(:instances) do
      add :display_name, :string
      add :soul_sha256, :string
      add :soul_version, :integer
      add :agents_md_sha256, :string
    end
  end
end
