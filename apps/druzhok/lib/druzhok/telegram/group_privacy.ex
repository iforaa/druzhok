defmodule Druzhok.Telegram.GroupPrivacy do
  @moduledoc """
  Whether a bot gets every message of its groups or only the ones addressed to
  it: Telegram's privacy mode, off when `can_read_all_group_messages` is true.
  With privacy on, Telegram never sends the bot a message that calls it by
  its group name (`trigger_name`) without an @mention, so that name only
  works with privacy off. Reading is not answering: `mention_only` still
  decides when the bot speaks. No admin rights are needed either way.

  Telegram keeps the setting and druzhok keeps no copy. Bot API 10.5's
  `setMySettings` changes it with the bot's own token, and `getMe` reads it
  back (the panel shows it through `Druzhok.Panel.profile/1`). Telegram applies it to a group when the
  bot joins, so a group the bot is already in needs it removed and added again.

  New managed bots start reading every message (`ManagerBot.Provisioner`); the owner switches it
  in the panel (`POST /app/api/group-privacy`).
  """

  alias Druzhok.Telegram.API

  @doc """
  Sets whether the bot reads every group message, then asks Telegram what it
  now holds. `{:ok, read_all?, me}` (`me` is the confirming getMe) only when
  Telegram reports the asked value, else `{:error, reason}`: setMySettings may
  have gone through even then, so the caller should read the value again.
  """
  def set(token, read_all?) when is_binary(token) and token != "" and is_boolean(read_all?) do
    with {:ok, _} <- API.set_my_settings(token, %{can_read_all_group_messages: read_all?}),
         {:ok, me} <- API.get_me(token) do
      case me do
        %{"can_read_all_group_messages" => ^read_all?} -> {:ok, read_all?, me}
        %{"can_read_all_group_messages" => other} -> {:error, {:not_applied, other}}
        _ -> {:error, :not_reported}
      end
    end
  end

  def set(_token, _read_all?), do: {:error, :no_token}
end
