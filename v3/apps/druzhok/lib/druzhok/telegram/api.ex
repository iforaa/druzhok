defmodule Druzhok.Telegram.API do
  @moduledoc """
  Raw Telegram Bot API client. No framework — just Finch HTTP calls.
  """

  @base_url "https://api.telegram.org/bot"

  def get_me(token) do
    call(token, "getMe", %{})
  end

  def get_updates(token, offset, timeout \\ 30) do
    call(token, "getUpdates", %{offset: offset, timeout: timeout})
  end

  def send_message(token, chat_id, text, opts \\ %{}) do
    call(token, "sendMessage", Map.merge(%{chat_id: chat_id, text: text}, opts))
  end

  def edit_message_text(token, chat_id, message_id, text, opts \\ %{}) do
    call(token, "editMessageText", Map.merge(%{
      chat_id: chat_id, message_id: message_id, text: text
    }, opts))
  end

  def send_document(token, chat_id, file_path, opts \\ %{}) do
    # For file sending, we need multipart upload — use a simple approach
    boundary = "----ElixirBoundary#{:rand.uniform(1_000_000)}"
    file_content = File.read!(file_path)
    filename = Path.basename(file_path)

    body = multipart_body(boundary, chat_id, filename, file_content, opts[:caption])

    headers = [
      {"content-type", "multipart/form-data; boundary=#{boundary}"}
    ]

    url = "#{@base_url}#{token}/sendDocument"
    case Finch.build(:post, url, headers, body) |> Finch.request(PiCore.Finch) do
      {:ok, %{status: 200, body: resp}} -> {:ok, Jason.decode!(resp)}
      {:ok, %{body: resp}} -> {:error, resp}
      {:error, reason} -> {:error, reason}
    end
  end

  def send_photo(token, chat_id, photo_bytes, opts \\ %{}) do
    boundary = "----ElixirBoundary#{:rand.uniform(1_000_000)}"
    caption = opts[:caption]

    body = IO.iodata_to_binary([
      "--#{boundary}\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n#{chat_id}\r\n",
      "--#{boundary}\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"image.png\"\r\nContent-Type: image/png\r\n\r\n",
      photo_bytes,
      "\r\n",
      if(caption, do: "--#{boundary}\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n#{caption}\r\n", else: ""),
      "--#{boundary}--\r\n"
    ])

    headers = [{"content-type", "multipart/form-data; boundary=#{boundary}"}]
    url = "#{@base_url}#{token}/sendPhoto"

    case Finch.build(:post, url, headers, body) |> Finch.request(PiCore.Finch) do
      {:ok, %{status: 200, body: resp}} -> {:ok, Jason.decode!(resp)}
      {:ok, %{body: resp}} -> {:error, resp}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_file(token, file_id) do
    call(token, "getFile", %{file_id: file_id})
  end

  def download_file(token, file_path) do
    url = "https://api.telegram.org/file/bot#{token}/#{file_path}"
    case Finch.build(:get, url) |> Finch.request(PiCore.Finch, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_file_by_id(token, file_id) do
    with {:ok, %{"file_path" => path}} <- get_file(token, file_id),
         {:ok, bytes} <- download_file(token, path) do
      {:ok, bytes}
    end
  end

  def send_chat_action(token, chat_id, action \\ "typing") do
    call(token, "sendChatAction", %{chat_id: chat_id, action: action})
  end

  defp call(token, method, params) do
    url = "#{@base_url}#{token}/#{method}"
    body = Jason.encode!(params)
    headers = [{"content-type", "application/json"}]

    case Finch.build(:post, url, headers, body) |> Finch.request(PiCore.Finch, receive_timeout: 35_000) do
      {:ok, %{status: 200, body: resp}} ->
        case Jason.decode!(resp) do
          %{"ok" => true, "result" => result} -> {:ok, result}
          other -> {:error, other}
        end
      {:ok, %{body: resp}} -> {:error, resp}
      {:error, reason} -> {:error, reason}
    end
  end

  # RFC 2046 multipart format
  defp multipart_body(boundary, chat_id, filename, content, caption) do
    parts = [
      "--#{boundary}\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n#{chat_id}\r\n",
      "--#{boundary}\r\nContent-Disposition: form-data; name=\"document\"; filename=\"#{filename}\"\r\nContent-Type: application/octet-stream\r\n\r\n#{content}\r\n",
    ]

    parts = if caption do
      parts ++ ["--#{boundary}\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n#{caption}\r\n"]
    else
      parts
    end

    Enum.join(parts) <> "--#{boundary}--\r\n"
  end
end
