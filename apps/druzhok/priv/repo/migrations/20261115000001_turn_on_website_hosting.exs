defmodule Druzhok.Repo.Migrations.TurnOnWebsiteHosting do
  use Ecto.Migration

  # Websites are now on for every bot, as they are for new ones
  # (`BotManager.insert/3`). The settings_seq bump makes the lifecycle controller
  # restart each running bot at its next quiet moment, so the bot gets the
  # `sites` tools and the prompt section; a sleeping bot picks it up on wake.
  def up do
    execute("""
    UPDATE instances
    SET website_hosting_enabled = 1,
        settings_seq = settings_seq + 1,
        settings_saved_at = strftime('%Y-%m-%d %H:%M:%f', 'now')
    WHERE website_hosting_enabled = 0
    """)
  end

  # Which bots had websites off before cannot be recovered.
  def down, do: :ok
end
