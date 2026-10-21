defmodule Druzhok.Lifecycle.Typing do
  @moduledoc """
  While a bot wakes for an update, show "typing…" in that update's chat
  (sleep/wake spec, "Typing indicator"). Druzhok sends it with the bot's own
  token, every 4 s until the update is delivered or 60 s pass. Best effort:
  a failed call is ignored.
  """

  require Logger
  alias Druzhok.{Instance, Repo}
  alias Druzhok.Telegram.{API, Inbox}

  def start(%Instance{} = inst) do
    with %Inbox{} = row <- Inbox.next_pending(inst.id),
         chat_id when not is_nil(chat_id) <- chat_id(row.payload),
         token when is_binary(token) and token != "" <- inst.telegram_token do
      Task.start(fn -> loop(token, chat_id, row.id, deadline()) end)
    end

    :ok
  end

  @doc "The chat an update belongs to, for the update types a user sends."
  def chat_id(payload) do
    case Jason.decode(payload) do
      {:ok, %{"message" => %{"chat" => %{"id" => id}}}} -> id
      {:ok, %{"edited_message" => %{"chat" => %{"id" => id}}}} -> id
      {:ok, %{"callback_query" => %{"message" => %{"chat" => %{"id" => id}}}}} -> id
      _ -> nil
    end
  end

  defp deadline,
    do: System.monotonic_time(:millisecond) + opt(:for_ms, 60_000)

  defp loop(token, chat_id, row_id, deadline) do
    if System.monotonic_time(:millisecond) < deadline and pending?(row_id) do
      try do
        API.send_chat_action(token, chat_id, "typing")
      rescue
        e -> Logger.debug("[life] typing: #{Exception.message(e)}")
      end

      Process.sleep(opt(:every_ms, 4_000))
      loop(token, chat_id, row_id, deadline)
    end
  end

  defp pending?(row_id) do
    case Repo.get(Inbox, row_id) do
      %Inbox{acked_at: nil, dropped_reason: nil} -> true
      _ -> false
    end
  end

  defp opt(key, default),
    do: Keyword.get(Application.get_env(:druzhok, :lifecycle_typing, []), key, default)
end
