defmodule Druzhok.Repo.Migrations.AddCabinet do
  use Ecto.Migration

  # Bot cabinet spec (ruoc-gateway docs/superpowers/specs/
  # 2026-10-24-telegram-mini-app-design.md), "druzhok": what Druzhok.Cabinet
  # last told ruoc and Telegram, so a start or a wake with nothing changed
  # costs no call.
  def change do
    alter table(:instances) do
      add(:cabinet_binding, :string)
      add(:cabinet_url, :string)
      add(:cabinet_menu_set, :boolean, null: false, default: false)
      # Set by `ops/druzhok bind-cabinet --off`, cleared by a plain
      # bind-cabinet: while set, nothing binds the bot or sets its button.
      add(:cabinet_off, :boolean, null: false, default: false)
    end
  end
end
