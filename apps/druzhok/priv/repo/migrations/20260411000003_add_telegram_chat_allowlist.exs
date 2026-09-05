defmodule Druzhok.Repo.Migrations.AddTelegramChatAllowlist do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      # JSON array of telegram group chat IDs that bypass require_mention
      # (bot responds freely in these chats, no trigger word needed).
      add :allowed_telegram_chats, :text

      # Bot responds to any Telegram user, not just the allowlisted ones.
      # NOTE: this flag applies platform-wide — DMs from unknown users are
      # also accepted. Pair with mention_only + trigger_name for group-only
      # bots, and be aware that DM spam is possible.
      add :allow_all_telegram_users, :boolean, default: false
    end
  end
end
