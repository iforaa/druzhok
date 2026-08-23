defmodule Druzhok.Repo.Migrations.DropHonchoSystemTenant do
  use Ecto.Migration

  def up do
    execute "DELETE FROM instances WHERE bot_runtime = 'system'"
  end

  def down, do: :ok
end
