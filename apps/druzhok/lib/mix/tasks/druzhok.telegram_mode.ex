defmodule Mix.Tasks.Druzhok.TelegramMode do
  @shortdoc "Switch a bot between Telegram polling and the webhook relay"
  @moduledoc """
  Usage (on the server, through ops/druzhok-run.sh so env and file caps apply):

      mix druzhok.telegram_mode <bot-name> webhook|polling [--force]

  Takes effect on the bot's next `Druzhok.BotManager.restart/1`. Leaving
  webhook mode is refused while updates are queued for the bot; `--force`
  drops them and says how many. See
  docs/superpowers/specs/2026-10-20-telegram-webhook-relay-design.md.
  """
  use Mix.Task

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: [force: :boolean]) do
      {opts, [name, mode], []} ->
        unless mode in Druzhok.Telegram.Webhook.modes(), do: usage()
        # :druzhok only — the relay belongs to the serving druzhok_web BEAM.
        {:ok, _} = Application.ensure_all_started(:druzhok)
        switch(name, mode, opts)

      _ ->
        usage()
    end
  end

  defp usage,
    do: Mix.raise("usage: mix druzhok.telegram_mode <bot-name> webhook|polling [--force]")

  defp switch(name, mode, opts) do
    case Druzhok.Telegram.Webhook.set_mode(name, mode, force: Keyword.get(opts, :force, false)) do
      {:ok, _instance, 0} ->
        Mix.shell().info(
          "#{name}: #{mode}. Restart it with Druzhok.BotManager.restart(\"#{name}\")."
        )

      {:ok, _instance, dropped} ->
        Mix.shell().info("#{name}: #{mode}, #{dropped} queued update(s) dropped. Restart it now.")

      {:error, :not_found} ->
        Mix.raise("no bot named #{name}")

      {:error, {:pending, n}} ->
        Mix.raise(
          "#{name} has #{n} queued update(s); wait for the relay or pass --force to drop them"
        )

      {:error, :busy} ->
        Mix.raise("#{name} keeps receiving updates; try again")

      {:error, {:id_out_of_range, id}} ->
        Mix.raise("#{name} has id #{id}; webhook ports cover ids 1-999 only")

      {:error, reason} ->
        Mix.raise("could not switch #{name}: #{inspect(reason)}")
    end
  end
end
