defmodule Druzhok.Repo.Migrations.AddFirstTasksSentAt do
  use Ecto.Migration

  # When the owner was offered the first-tasks keyboard (`Druzhok.Cabinet`),
  # which goes out once per bot. Every bot made before already had it on its
  # /starts, or is old enough not to need it, so they are all marked now.
  def up do
    alter table(:instances) do
      add(:first_tasks_sent_at, :utc_datetime_usec)
    end

    flush()
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    execute("UPDATE instances SET first_tasks_sent_at = '#{now}'")
  end

  def down do
    alter table(:instances) do
      remove(:first_tasks_sent_at)
    end
  end
end
