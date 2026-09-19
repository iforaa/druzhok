defmodule Druzhok.Repo.Migrations.CreateAdmissions do
  use Ecto.Migration

  # Who may create a bot. A row is written when ruoc-gateway accepted the
  # person's invite code at account creation, and is never removed: deleting
  # the bot does not take the admission back, so a rename needs no new code.
  # Everyone who owns a bot when this runs is admitted, so the invite gate
  # locks nobody out who is already here.
  #
  # The timestamp shape matches what `Repo.insert_all` writes for a
  # `:utc_datetime`, so the column never holds two formats.
  @grandfather_sql """
  insert into admissions (telegram_id, invite_hint, admitted_at)
  select distinct owner_telegram_id, 'grandfathered', strftime('%Y-%m-%dT%H:%M:%S', 'now')
  from instances where owner_telegram_id is not null
  """

  @doc "The grandfathering insert, exposed so a test can replay it."
  def grandfather_sql, do: @grandfather_sql

  def up do
    create table(:admissions) do
      add :telegram_id, :integer, null: false
      add :invite_hint, :string, null: false, default: ""
      add :admitted_at, :utc_datetime, null: false
    end

    create unique_index(:admissions, [:telegram_id])

    execute(@grandfather_sql)
  end

  def down, do: drop(table(:admissions))
end
