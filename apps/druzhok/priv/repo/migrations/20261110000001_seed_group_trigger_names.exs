defmodule Druzhok.Repo.Migrations.SeedGroupTriggerNames do
  use Ecto.Migration

  def up do
    rows =
      repo().query!("""
      SELECT id, display_name FROM instances
      WHERE (trigger_name IS NULL OR trigger_name = '') AND display_name IS NOT NULL
      """).rows

    # Match creation and the panel: String.length counts graphemes, unlike
    # SQLite length, which would skip valid decomposed or emoji names.
    for [id, display_name] <- rows,
        name = String.trim(display_name),
        name != "" and String.length(name) <= 32 do
      repo().query!(
        """
        UPDATE instances
        SET trigger_name = ?,
            settings_seq = settings_seq + 1,
            settings_saved_at = strftime('%Y-%m-%d %H:%M:%f', 'now')
        WHERE id = ? AND (trigger_name IS NULL OR trigger_name = '')
        """,
        [name, id]
      )
    end
  end

  # The previous nil/empty value and any later owner edit cannot be recovered.
  def down, do: :ok
end
