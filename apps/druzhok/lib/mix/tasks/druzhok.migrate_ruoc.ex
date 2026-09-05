defmodule Mix.Tasks.Druzhok.MigrateRuoc do
  @shortdoc "Move a bot onto ruoc-gateway: create its account, remap its model, restart it"
  @moduledoc """
  Usage (on the server, through ops/druzhok-run.sh so env and file caps apply):

      mix druzhok.migrate_ruoc <bot-name>

  Idempotent. Funding is a separate step in the ruoc console; the task prints
  the account id to fund.
  """
  use Mix.Task

  @impl true
  def run([name]) do
    Mix.Task.run("app.start")

    case Druzhok.BotManager.migrate_to_ruoc(name) do
      {:ok, %{account_id: id, model: model}} ->
        Mix.shell().info("#{name}: migrated to ruoc account #{id}, model #{model}. Fund it in the ruoc console.")

      {:already_migrated, _} ->
        Mix.shell().info("#{name}: already on ruoc")

      {:error, :not_found} ->
        Mix.raise("no bot named #{name}")

      {:error, reason} ->
        Mix.raise("migration failed: #{inspect(reason)}")
    end
  end

  def run(_), do: Mix.raise("usage: mix druzhok.migrate_ruoc <bot-name>")
end
