defmodule Druzhok.Telegram.API do
  @moduledoc """
  Raw Telegram Bot API client. No framework — just Finch HTTP calls.
  """

  def get_me(token) do
    call(token, "getMe", %{})
  end

  def get_updates(token, offset, timeout \\ 30) do
    call(token, "getUpdates", %{offset: offset, timeout: timeout})
  end

  def send_message(token, chat_id, text, opts \\ %{}) do
    call(token, "sendMessage", Map.merge(%{chat_id: chat_id, text: text}, opts))
  end

  def delete_message(token, chat_id, message_id) do
    call(token, "deleteMessage", %{chat_id: chat_id, message_id: message_id})
  end

  def set_webhook(token, params), do: call(token, "setWebhook", params)

  def send_photo(token, chat_id, photo, opts \\ %{})

  def send_photo(token, chat_id, {:upload, bytes}, opts) do
    boundary = "druzhok-" <> Base.encode16(:crypto.strong_rand_bytes(16))
    fields = Map.merge(%{chat_id: chat_id}, opts)

    body =
      Enum.map(fields, fn {key, value} ->
        value = if is_map(value), do: Jason.encode!(value), else: to_string(value)

        [
          "--",
          boundary,
          "\r\nContent-Disposition: form-data; name=\"",
          to_string(key),
          "\"\r\n\r\n",
          value,
          "\r\n"
        ]
      end)

    body = [
      body,
      "--",
      boundary,
      "\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"intro.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n",
      bytes,
      "\r\n--",
      boundary,
      "--\r\n"
    ]

    request(
      token,
      "sendPhoto",
      [{"content-type", "multipart/form-data; boundary=" <> boundary}],
      body
    )
  end

  def send_photo(token, chat_id, photo, opts),
    do: call(token, "sendPhoto", Map.merge(%{chat_id: chat_id, photo: photo}, opts))

  def edit_message_text(token, chat_id, message_id, text, opts \\ %{}) do
    call(
      token,
      "editMessageText",
      Map.merge(
        %{
          chat_id: chat_id,
          message_id: message_id,
          text: text
        },
        opts
      )
    )
  end

  def send_chat_action(token, chat_id, action \\ "typing") do
    call(token, "sendChatAction", %{chat_id: chat_id, action: action})
  end

  def answer_callback_query(token, callback_query_id, opts \\ %{}) do
    call(token, "answerCallbackQuery", Map.merge(%{callback_query_id: callback_query_id}, opts))
  end

  @doc "Sets one chat's menu button (`chat_id`), e.g. `%{type: \"web_app\", text: …, web_app: %{url: …}}`."
  def set_chat_menu_button(token, chat_id, menu_button) do
    call(token, "setChatMenuButton", %{chat_id: chat_id, menu_button: menu_button})
  end

  def get_managed_bot_token(token, bot_user_id) do
    call(token, "getManagedBotToken", %{user_id: bot_user_id})
  end

  # Overridable so tests can point the client at a local stub.
  defp base_url,
    do: Application.get_env(:druzhok, :telegram_api_base) || "https://api.telegram.org"

  defp bot_url(token, method), do: "#{base_url()}/bot#{token}/#{method}"

  defp call(token, method, params) do
    body = Jason.encode!(params)
    headers = [{"content-type", "application/json"}]

    request(token, method, headers, body)
  end

  defp request(token, method, headers, body) do
    case Finch.build(:post, bot_url(token, method), headers, body)
         |> Finch.request(Druzhok.Finch, receive_timeout: 35_000) do
      {:ok, %{status: 200, body: resp}} ->
        case Jason.decode!(resp) do
          %{"ok" => true, "result" => result} -> {:ok, result}
          other -> {:error, other}
        end

      {:ok, %{body: resp}} ->
        {:error, resp}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
