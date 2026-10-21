defmodule Druzhok.Telegram.Addressed do
  @moduledoc """
  Whether an update may make a sleeping bot answer, so it is worth waking it
  (sleep/wake spec, "Waking only for addressed updates").

  Only a plain group message the bot would skip is not: hermes, with
  `TELEGRAM_REQUIRE_MENTION` on, answers a group message only when it
  @mentions the bot, replies to it, carries a command, matches the trigger
  name, or comes from a free-response chat. Everything else (private chats,
  callbacks, membership changes, updates of a kind not listed here) wakes the
  bot. When in doubt this says yes: a needless wake costs a start, a missed
  one costs an answer.

  A skipped row stays queued and is delivered, in order, on the next wake, so
  a bot that observes group chatter (`group_shared_memory`) still sees it.
  """

  require Logger
  alias Druzhok.Telegram.API

  @group_types ["group", "supergroup"]

  @doc "`true` when `update` (a decoded map) should wake `instance`."
  def wakes?(instance, update) do
    case group_message(update) do
      nil -> true
      msg -> not Map.get(instance, :mention_only, false) or addressed?(instance, msg)
    end
  end

  defp group_message(update) do
    msg = update["message"] || update["edited_message"]

    case msg do
      %{"chat" => %{"type" => type}} when type in @group_types -> msg
      _ -> nil
    end
  end

  defp addressed?(instance, msg) do
    free_response?(instance, msg) or reply_to_bot?(instance, msg) or
      command?(msg) or mentions_bot?(instance, msg) or trigger?(instance, msg)
  end

  defp free_response?(instance, %{"chat" => %{"id" => id}}),
    do: to_string(id) in free_response_chats(instance)

  defp free_response_chats(instance) do
    case Jason.decode(Map.get(instance, :allowed_telegram_chats) || "") do
      {:ok, list} when is_list(list) -> Enum.map(list, &to_string/1)
      _ -> []
    end
  end

  defp reply_to_bot?(instance, msg) do
    case get_in(msg, ["reply_to_message", "from", "id"]) do
      nil -> false
      id -> id == bot_id(instance)
    end
  end

  defp command?(msg), do: Enum.any?(entities(msg), &(&1["type"] == "bot_command"))

  defp mentions_bot?(instance, msg) do
    text = text(msg)

    Enum.any?(entities(msg), fn
      %{"type" => "text_mention", "user" => %{"id" => id}} ->
        id == bot_id(instance)

      %{"type" => "mention", "offset" => offset, "length" => length} ->
        case username(instance) do
          nil -> true
          name -> String.downcase(utf16_slice(text, offset, length)) == "@" <> name
        end

      _ ->
        false
    end)
  end

  # Hermes compiles the same `\bname\b` pattern case-insensitively
  # (Runtime.Hermes.build_mention_patterns/1).
  defp trigger?(instance, msg) do
    case Map.get(instance, :trigger_name) do
      name when is_binary(name) and name != "" ->
        Regex.match?(~r/(?<!\w)#{Regex.escape(name)}(?!\w)/iu, text(msg))

      _ ->
        false
    end
  end

  defp text(msg), do: msg["text"] || msg["caption"] || ""
  defp entities(msg), do: msg["entities"] || msg["caption_entities"] || []

  # Telegram entity offsets count UTF-16 code units.
  defp utf16_slice(text, offset, length) do
    bin = :unicode.characters_to_binary(text, :utf8, {:utf16, :little})

    case bin do
      <<_::binary-size(offset * 2), part::binary-size(length * 2), _::binary>> ->
        :unicode.characters_to_binary(part, {:utf16, :little}, :utf8)

      _ ->
        ""
    end
  end

  # The numeric part of the token is the bot's user id.
  defp bot_id(instance) do
    with token when is_binary(token) <- Map.get(instance, :telegram_token),
         [id, _] <- String.split(token, ":", parts: 2),
         {n, ""} <- Integer.parse(id) do
      n
    else
      _ -> nil
    end
  end

  @doc """
  The bot's @username, lowercased, from `getMe`, cached per token for the
  life of the BEAM. Never waits on Telegram: on a miss it starts the lookup
  and answers `nil`, and every @mention then counts as addressed.
  """
  def username(instance) do
    case Map.get(instance, :telegram_token) do
      token when is_binary(token) and token != "" ->
        key = {__MODULE__, :crypto.hash(:sha256, token)}

        case :persistent_term.get(key, nil) do
          name when is_binary(name) ->
            name

          tried_at ->
            if is_nil(tried_at) or System.monotonic_time(:second) - tried_at > 60 do
              :persistent_term.put(key, System.monotonic_time(:second))
              Task.start(fn -> fetch_username(key, token) end)
            end

            nil
        end

      _ ->
        nil
    end
  end

  defp fetch_username(key, token) do
    {mod, fun} =
      Application.get_env(:druzhok, :telegram_username_fun, {__MODULE__, :get_me_username})

    case apply(mod, fun, [token]) do
      name when is_binary(name) and name != "" -> :persistent_term.put(key, String.downcase(name))
      _ -> :ok
    end
  end

  @doc false
  def get_me_username(token) do
    case API.get_me(token) do
      {:ok, %{"username" => name}} ->
        name

      other ->
        Logger.warning("[relay] getMe failed: #{inspect(other) |> String.slice(0, 200)}")
        nil
    end
  rescue
    e ->
      Logger.warning("[relay] getMe failed: #{Exception.message(e)}")
      nil
  end
end
