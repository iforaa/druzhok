defmodule Druzhok.Repo.Migrations.AddDailyTokenLimitToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :daily_token_limit, :integer, default: 0
    end
  end
end
