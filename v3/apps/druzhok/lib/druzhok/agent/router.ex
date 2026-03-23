defmodule Druzhok.Agent.Router do
  @moduledoc """
  Pure functions for classifying and extracting data from Telegram updates.
  No side effects — all I/O stays in Agent.Telegram.
  """

  @doc """
  Classify a Telegram update into a routing category.

  Returns:
    - `{:dm, message}` for private chats
    - `{:group, message, chat_title}` for group/supergroup chats
    - `:ignore` for bot messages, unknown updates, etc.
  """
  def classify(%{"message" => msg}) do
    from = msg["from"]

    cond do
      is_nil(from) or from["is_bot"] ->
        :ignore

      (msg["chat"]["type"] || "private") == "private" ->
        {:dm, msg}

      msg["chat"]["type"] in ["group", "supergroup"] ->
        {:group, msg, msg["chat"]["title"]}

      true ->
        :ignore
    end
  end

  def classify(_), do: :ignore

  @doc """
  Extract text content from a Telegram message map.
  Falls back to caption (for photos/documents), then empty string.
  """
  def extract_text(msg) do
    msg["text"] || msg["caption"] || ""
  end

  @doc """
  Extract file info from a Telegram message, if any attachment is present.

  Returns `%{file_id: id, name: name}` or `nil`.
  """
  def extract_file(msg) do
    cond do
      msg["document"] ->
        %{file_id: msg["document"]["file_id"], name: msg["document"]["file_name"] || "document"}

      msg["photo"] ->
        %{file_id: List.last(msg["photo"])["file_id"], name: "photo.jpg"}

      msg["voice"] ->
        %{file_id: msg["voice"]["file_id"], name: "voice.ogg"}

      msg["audio"] ->
        %{file_id: msg["audio"]["file_id"], name: msg["audio"]["file_name"] || "audio.mp3"}

      msg["video"] ->
        %{file_id: msg["video"]["file_id"], name: msg["video"]["file_name"] || "video.mp4"}

      msg["sticker"] ->
        %{file_id: msg["sticker"]["file_id"], name: "sticker.webp"}

      true ->
        nil
    end
  end

  @doc """
  Parse a Telegram update into structured message data.

  Returns `{chat_id, chat_type, text, sender_id, sender_name, file, chat_title}` or `nil`.
  """
  def extract_message(%{"message" => msg}) do
    from = msg["from"]

    if from && !from["is_bot"] do
      chat_id = msg["chat"]["id"]
      chat_type = msg["chat"]["type"] || "private"
      text = extract_text(msg)
      sender_id = from["id"]
      name = [from["first_name"], from["last_name"]] |> Enum.reject(&is_nil/1) |> Enum.join(" ")
      file = extract_file(msg)
      chat_title = msg["chat"]["title"]
      {chat_id, chat_type, text, sender_id, name, file, chat_title}
    else
      nil
    end
  end

  def extract_message(_), do: nil

  @doc """
  Check if the bot was triggered in a group message by text content.

  Returns true if the text contains `@username` or matches the bot's name regex.
  Reply-to-bot detection is handled separately via `reply_to_bot?/2`.
  """
  def triggered?(text, bot_username, bot_name_regex) do
    mentioned_by_username?(text, bot_username) ||
      name_mentioned?(text, bot_name_regex)
  end

  @doc """
  Check if `@username` appears in the text (case-insensitive).
  """
  def mentioned_by_username?(_text, nil), do: false

  def mentioned_by_username?(text, username) do
    String.contains?(String.downcase(text), "@" <> String.downcase(username))
  end

  @doc """
  Check if the bot's name regex matches the text.
  """
  def name_mentioned?(_text, nil), do: false
  def name_mentioned?(text, regex), do: Regex.match?(regex, text)

  @doc """
  Check if an update is a reply to the bot.
  """
  def reply_to_bot?(%{"message" => %{"reply_to_message" => %{"from" => %{"id" => id}}}}, bot_id)
      when not is_nil(bot_id) do
    id == bot_id
  end

  def reply_to_bot?(_, _), do: false

  @doc """
  Parse a command from message text.

  Returns `{:command, name}`, `{:command, name, arg}`, or `:text`.
  """
  def parse_command("/start" <> _), do: {:command, "start"}
  def parse_command("/reset" <> _), do: {:command, "reset"}
  def parse_command("/abort" <> _), do: {:command, "abort"}
  def parse_command("/mode " <> arg), do: {:command, "mode", String.trim(arg)}
  def parse_command("/mode"), do: {:command, "mode", ""}
  def parse_command("/" <> _), do: :text
  def parse_command(_), do: :text
end
