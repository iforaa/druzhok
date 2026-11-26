defmodule Druzhok.Repo.Migrations.AddGroupImagesEnabled do
  use Ecto.Migration

  # «Картинки в группах»: on for every bot, existing ones included. It reaches
  # hermes only where pictures are on too (`Runtime.Hermes.sync_telegram_extra`),
  # so those bots get a settings_seq bump: the lifecycle controller restarts
  # each running one at its next quiet moment, a sleeping one picks it up on wake.
  def up do
    alter table(:instances) do
      add(:group_images_enabled, :boolean, null: false, default: true)
    end

    flush()

    execute("""
    UPDATE instances
    SET settings_seq = settings_seq + 1,
        settings_saved_at = strftime('%Y-%m-%d %H:%M:%f', 'now')
    WHERE image_gen_enabled = 1
    """)
  end

  def down do
    alter table(:instances) do
      remove(:group_images_enabled)
    end
  end
end
