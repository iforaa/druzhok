defmodule Druzhok.Telegram.Addressed do
  @moduledoc """
  Whether an update may make a sleeping bot answer, so it is worth waking it
  (sleep/wake spec, "Waking only for addressed updates").

  Only a plain group message the bot would skip is not: hermes, with
  `TELEGRAM_REQUIRE_MENTION` on, answers a group message only when it
  @mentions the bot, replies to it, matches the trigger
  name, or comes from a free-response chat. Everything else (private chats,
  callbacks, membership changes, updates of a kind not listed here) wakes the
  bot. When in doubt this says yes: a needless wake costs a start, a missed
  one costs an answer.

  A skipped row stays queued and is delivered, in order, on the next wake.
  Only approved groups get this far (`Druzhok.GroupChats`).
  """

  require Logger
  alias Druzhok.Telegram.API

  @group_types ["group", "supergroup"]

  @doc "`true` when `update` (a decoded map) should wake `instance`."
  def wakes?(instance, update) do
    case group_message(update) do
      nil ->
        true

      msg ->
        not command?(msg) and not mentions_only_other_bots?(instance, msg) and
          (not Map.get(instance, :mention_only, false) or addressed?(instance, msg))
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
      mentions_bot?(instance, msg) or trigger?(instance, msg)
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

  # MessageEvent.get_command(): remove leading attachment refs/whitespace,
  # take the first slash token, drop @target, and reject file paths.
  defp command?(msg) do
    command_text =
      text(msg)
      |> String.trim_leading()
      |> then(&Regex.replace(~r/^(?:@(?:image|file|url):[^\n]+\n?)+/i, &1, ""))
      |> String.trim_leading()

    case command_text do
      "/" <> rest ->
        command =
          rest |> String.split(~r/\s/u, parts: 2) |> hd() |> String.split("@", parts: 2) |> hd()

        command != "" and not String.contains?(command, "/")

      _ ->
        false
    end
  end

  # Mirror Hermes's exclusive bot-mention veto, including its narrow fallback
  # only when Telegram supplied no entities. Human handles never veto a name.
  defp mentions_only_other_bots?(instance, msg) do
    case username(instance) do
      nil ->
        false

      own ->
        handles =
          for {source, source_entities} <- entity_sources(msg),
              handle <- bot_handles(source, source_entities),
              handle == own or Regex.match?(~r/^[a-z0-9_]{2,29}bot$/i, handle),
              do: handle

        handles != [] and own not in handles
    end
  end

  defp entity_sources(msg),
    do: [
      {msg["text"] || "", msg["entities"] || []},
      {msg["caption"] || "", msg["caption_entities"] || []}
    ]

  defp bot_handles(source, []) do
    Regex.scan(~r/(?<![A-Za-z0-9_`\/])@([A-Za-z0-9_]{2,31})\b/iu, source, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
  end

  defp bot_handles(source, source_entities) do
    Enum.flat_map(source_entities, fn
      %{"type" => type, "offset" => offset, "length" => length}
      when type in ["mention", "bot_command"] ->
        span = source |> utf16_slice(offset, length) |> String.trim() |> String.downcase()

        case {type, String.split(span, "@", parts: 2)} do
          {"mention", _} -> [String.trim_leading(span, "@")]
          {"bot_command", [_, target]} -> [String.trim(target)]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp mentions_bot?(instance, msg) do
    text = text(msg)

    Enum.any?(entities(msg), fn
      %{"type" => "text_mention", "user" => %{"id" => id}} ->
        id == bot_id(instance)

      %{"type" => "bot_command", "offset" => offset, "length" => length} ->
        case {username(instance), String.split(utf16_slice(text, offset, length), "@", parts: 2)} do
          {name, [_, target]} when is_binary(name) -> String.downcase(String.trim(target)) == name
          _ -> false
        end

      %{"type" => "mention", "offset" => offset, "length" => length} ->
        case username(instance) do
          nil -> true
          name -> String.downcase(utf16_slice(text, offset, length)) == "@" <> name
        end

      _ ->
        false
    end)
  end

  # Hermes compiles the same Unicode lookaround pattern case-insensitively
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
  next hour. Never waits on Telegram: on a miss it starts the lookup
  and answers `nil`, and every @mention then counts as addressed.
  """
  def username(instance) do
    case Map.get(instance, :telegram_token) do
      token when is_binary(token) and token != "" ->
        key = {__MODULE__, :crypto.hash(:sha256, token)}

        case :persistent_term.get(key, nil) do
          {name, fetched_at} when is_binary(name) ->
            if System.monotonic_time(:second) - fetched_at < 3600 do
              name
            else
              start_lookup(key, token)
              nil
            end

          name when is_binary(name) ->
            # Entries written before the TTL was introduced have no timestamp.
            start_lookup(key, token)
            nil

          tried_at ->
            if is_nil(tried_at) or System.monotonic_time(:second) - tried_at > 60 do
              start_lookup(key, token)
            end

            nil
        end

      _ ->
        nil
    end
  end

  defp start_lookup(key, token) do
    :persistent_term.put(key, System.monotonic_time(:second))
    Task.start(fn -> fetch_username(key, token) end)
  end

  defp fetch_username(key, token) do
    {mod, fun} =
      Application.get_env(:druzhok, :telegram_username_fun, {__MODULE__, :get_me_username})

    case apply(mod, fun, [token]) do
      name when is_binary(name) and name != "" ->
        :persistent_term.put(key, {String.downcase(name), System.monotonic_time(:second)})

      _ ->
        :ok
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
