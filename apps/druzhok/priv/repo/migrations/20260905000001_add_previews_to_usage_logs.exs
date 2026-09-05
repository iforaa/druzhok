defmodule Druzhok.Repo.Migrations.AddPreviewsToUsageLogs do
  use Ecto.Migration

  # `Druzhok.Usage` has written these columns since the proxy started logging
  # previews, but prod got them via a manual ALTER TABLE and no migration was
  # ever committed. Add whichever ones are missing so fresh databases work.
  @columns ~w(prompt_preview response_preview request_body)

  def up do
    existing =
      repo().query!("PRAGMA table_info(usage_logs)").rows
      |> Enum.map(&Enum.at(&1, 1))

    for col <- @columns, col not in existing do
      execute("ALTER TABLE usage_logs ADD COLUMN #{col} TEXT")
    end
  end

  def down do
    alter table(:usage_logs) do
      remove :prompt_preview
      remove :response_preview
      remove :request_body
    end
  end
end
