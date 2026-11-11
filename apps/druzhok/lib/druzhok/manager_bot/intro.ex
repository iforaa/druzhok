defmodule Druzhok.ManagerBot.Intro do
  @moduledoc false
  alias Druzhok.Telegram.API

  def send(token, chat_id, caption, keyboard) do
    path =
      Application.get_env(:druzhok, :onboarding_intro_path) ||
        Application.app_dir(:druzhok, "priv/onboarding/intro.jpg")

    with {:ok, bytes} <- File.read(path) do
      key = {__MODULE__, :crypto.hash(:sha256, bytes)}
      photo = :persistent_term.get(key, {:upload, bytes})

      case API.send_photo(token, chat_id, photo, %{caption: caption, reply_markup: keyboard}) do
        {:ok, %{"photo" => [_ | _] = photos} = result} ->
          largest = Enum.max_by(photos, &((&1["width"] || 0) * (&1["height"] || 0)))
          :persistent_term.put(key, Map.fetch!(largest, "file_id"))
          {:ok, result}

        {:ok, _} ->
          {:error, :missing_photo}

        error ->
          error
      end
    end
  rescue
    _ -> {:error, :photo_failed}
  end
end
