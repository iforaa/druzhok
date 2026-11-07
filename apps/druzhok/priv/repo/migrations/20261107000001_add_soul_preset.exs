defmodule Druzhok.Repo.Migrations.AddSoulPreset do
  use Ecto.Migration

  # The character the owner picked in the superbot (`Voice.soul_md/2`); nil
  # for «Пропустить» and every bot made before, which keep today's SOUL.md.
  def change do
    alter table(:instances) do
      add(:soul_preset, :string)
    end
  end
end
