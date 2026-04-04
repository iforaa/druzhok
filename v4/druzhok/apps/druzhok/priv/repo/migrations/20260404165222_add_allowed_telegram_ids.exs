defmodule Druzhok.Repo.Migrations.AddAllowedTelegramIds do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :allowed_telegram_ids, :string
    end
  end
end
