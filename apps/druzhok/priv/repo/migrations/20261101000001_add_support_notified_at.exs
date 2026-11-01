defmodule Druzhok.Repo.Migrations.AddSupportNotifiedAt do
  use Ecto.Migration

  # The newest support reply Druzhok.Cabinet has told the owner about (ruoc's
  # `latest_at`), so a restart neither repeats a note nor misses one.
  def change do
    alter table(:instances) do
      add(:support_notified_at, :utc_datetime_usec)
    end
  end
end
