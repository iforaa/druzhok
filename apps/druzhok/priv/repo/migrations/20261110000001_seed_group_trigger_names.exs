defmodule Druzhok.Repo.Migrations.SeedGroupTriggerNames do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE instances
    SET trigger_name = trim(display_name),
        settings_seq = settings_seq + 1,
        settings_saved_at = strftime('%Y-%m-%d %H:%M:%f', 'now')
    WHERE (trigger_name IS NULL OR trigger_name = '')
      AND length(trim(display_name)) BETWEEN 1 AND 32
    """)
  end

  # The previous nil/empty value and any later owner edit cannot be recovered.
  def down, do: :ok
end
