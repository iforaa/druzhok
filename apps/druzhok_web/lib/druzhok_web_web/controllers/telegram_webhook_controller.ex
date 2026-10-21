defmodule DruzhokWebWeb.TelegramWebhookController do
  @moduledoc """
  Telegram's webhook for webhook-mode bots: `POST /telegram/webhook/:bot`.

  Checks the per-bot secret Telegram echoes in
  `X-Telegram-Bot-Api-Secret-Token`, stores the update and answers 200 at
  once; `Druzhok.Telegram.Relay` hands it to the bot. The 200 goes out only
  after the row is committed, so an update is either queued here or still
  held (and retried) by Telegram.
  """

  use DruzhokWebWeb, :controller
  require Logger
  alias Druzhok.{Instance, Repo}
  alias Druzhok.Telegram.{Addressed, Inbox, Relay, Webhook}

  def receive(conn, %{"bot" => name}) do
    with %Instance{} = instance <- Repo.get_by(Instance, name: name),
         true <- Webhook.webhook?(instance) do
      if secret_ok?(conn, instance) do
        store(conn, instance)
      else
        send_resp(conn, 401, "")
      end
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  defp secret_ok?(conn, %Instance{telegram_webhook_secret: secret})
       when is_binary(secret) and secret != "" do
    case get_req_header(conn, "x-telegram-bot-api-secret-token") do
      [given] -> Plug.Crypto.secure_compare(given, secret)
      _ -> false
    end
  end

  defp secret_ok?(_conn, _instance), do: false

  defp store(conn, instance) do
    case conn.body_params do
      %{"update_id" => update_id} = update when is_integer(update_id) ->
        wakes = Addressed.wakes?(instance, update)

        case Inbox.enqueue(instance.id, update_id, Jason.encode!(update), wakes: wakes) do
          :ok ->
            Relay.notify(instance.id)
            send_resp(conn, 200, "")

          # Switched to polling since the lookup above: Telegram keeps the
          # update and the polling bot fetches it itself.
          {:error, :not_webhook} ->
            send_resp(conn, 404, "")
        end

      _ ->
        send_resp(conn, 400, "")
    end
  rescue
    error ->
      Logger.error(
        "[telegram webhook] #{instance.name}: could not queue update: #{Exception.message(error)}"
      )

      send_resp(conn, 500, "")
  end
end
