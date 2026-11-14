defmodule Druzhok.Avatar do
  @moduledoc """
  A new bot's own face: right after the superbot reports «Бот создан», a
  picture is drawn through ruoc (`POST /v1/images`, under the bot's own key,
  so it is one picture on the bot's plan), turned into a 640×640 JPEG by
  ffmpeg and set with the bot's token (`setMyProfilePhoto`). It never blocks
  or fails creation: any step that fails is logged and the bot keeps
  Telegram's letter avatar. Off in tests (`config :druzhok, :bot_avatars`).

  `redraw/2` is the same drawing from the owner's own description (CleoHub's
  `cleohub_set_avatar`), and it reports what went wrong, for the owner's message.
  """

  require Logger

  alias Druzhok.{Instance, Repo}
  alias Druzhok.Ruoc.Client
  alias Druzhok.Telegram.API

  # Brand colours of the Cleo icon, so every new bot sits in the same family.
  @pink "#F5089E"
  @violet "#3A22D8"

  @looks %{
    "friendly" => "warm and smiling",
    "business" => "neat and confident, with small round glasses",
    "humor" => "playful, winking, with a cheeky grin",
    "brief" => "calm and focused, minimal features"
  }

  @doc "Draw and set the avatar of bot `name` in the background. Returns at once."
  def start(name) when is_binary(name) do
    if Application.get_env(:druzhok, :bot_avatars, true) do
      Task.start(fn -> run(name) end)
    else
      :ignore
    end
  end

  @doc false
  def run(name) do
    with %Instance{telegram_token: token, ruoc_api_key: key} = inst
         when is_binary(token) and is_binary(key) <- Repo.get_by(Instance, name: name),
         {:ok, _jpeg} <- draw_and_set(inst, prompt(inst)) do
      Logger.info("[avatar] #{name}: set")
      :ok
    else
      nil -> Logger.warning("[avatar] #{name}: no bot or no keys")
      %Instance{} -> Logger.warning("[avatar] #{name}: no bot or no keys")
      {:error, reason} -> Logger.warning("[avatar] #{name}: #{short(reason)}")
    end
  rescue
    e -> Logger.warning("[avatar] #{name}: crashed (#{Exception.message(e)})")
  end

  @doc """
  Draw the bot's avatar from `description` (the owner's words, the look in
  `prompt/2`) and set it. `{:ok, jpeg}` with what was set, or `{:error, reason}`;
  `reason/1` puts a reason in the owner's words. Never raises.
  """
  def redraw(%Instance{telegram_token: token, ruoc_api_key: key} = inst, description)
      when is_binary(token) and is_binary(key) and is_binary(description) do
    case draw_and_set(inst, prompt(inst, description)) do
      {:ok, jpeg} ->
        Logger.info("[avatar] #{inst.name}: redrawn")
        {:ok, jpeg}

      {:error, reason} = error ->
        Logger.warning("[avatar] #{inst.name}: redraw failed: #{short(reason)}")
        error
    end
  rescue
    e ->
      Logger.warning("[avatar] #{inst.name}: redraw crashed (#{Exception.message(e)})")
      {:error, :crashed}
  end

  def redraw(%Instance{}, _description), do: {:error, :no_keys}

  # Every step's failure comes back tagged with where it happened.
  defp draw_and_set(%Instance{telegram_token: token, ruoc_api_key: key}, prompt) do
    with {:ok, image} <- draw(key, prompt),
         {:ok, jpeg} <- to_jpeg(image),
         :ok <- set_photo(token, jpeg) do
      {:ok, jpeg}
    end
  end

  defp set_photo(token, jpeg) do
    case API.set_my_profile_photo(token, jpeg) do
      {:ok, true} -> :ok
      other -> {:error, {:telegram, other}}
    end
  end

  @doc """
  Why a redraw failed, short and in `lang` ("ru" or "en"), for the owner. Never
  the balance: an empty account is «the plan's limit», as the cabinet shows it.
  """
  def reason(reason, lang \\ "ru")

  def reason({:ruoc, status, _}, lang) when status in [402, 429], do: say(lang, :limit)
  def reason({:ruoc, status, _}, lang) when status in [400, 422], do: say(lang, :refused)
  def reason({:ruoc, _, _}, lang), do: say(lang, :service)
  def reason(:bad_image_reply, lang), do: say(lang, :service)
  def reason({:ffmpeg, _, _}, lang), do: say(lang, :convert)
  def reason({:telegram, _}, lang), do: say(lang, :telegram)
  def reason(:no_keys, lang), do: say(lang, :no_keys)
  def reason(_, lang), do: say(lang, :service)

  @reasons %{
    limit: {"лимит тарифа исчерпан, подробности в «Кабинете»", "the plan's limit is used up, see «Cabinet»"},
    refused: {"сервис картинок отказался рисовать по этому описанию", "the picture service refused this description"},
    service: {"сервис картинок не ответил, попробуйте позже", "the picture service did not answer, try again later"},
    convert: {"не удалось обработать картинку", "the picture could not be processed"},
    telegram: {"Telegram не принял картинку", "Telegram did not accept the picture"},
    no_keys: {"бот ещё не настроен", "the bot is not set up yet"}
  }

  defp say("en", key), do: elem(@reasons[key], 1)
  defp say(_, key), do: elem(@reasons[key], 0)

  @doc """
  The image prompt for a bot: its name and character, in Cleo colours. With
  `description` (the owner's words, at most 300 characters) that is the look,
  and it wins over the house style wherever they differ.
  """
  def prompt(%Instance{} = inst, description \\ nil) do
    name = inst.display_name || inst.name

    case description do
      nil ->
        look = Map.get(@looks, inst.soul_preset || "", "friendly and kind")

        "Flat vector app-icon style avatar of a cute cartoon character who is a personal AI helper named " <>
          "\"#{name}\": #{look}. If the name suggests an animal or a creature, draw that; otherwise a small friendly robot. " <>
          "One character, centred, head and shoulders, filling the middle of the frame, simple bold shapes, white outline. " <>
          "Background split horizontally: hot pink #{@pink} top half, deep violet #{@violet} bottom half. " <>
          "No text, no letters, no words, no watermark. Keep everything important inside the central circle."

      description ->
        "Avatar of a personal AI helper named \"#{name}\". The owner describes it: \"#{description}\". " <>
          "Draw what the description asks for; where it says nothing, use a flat vector app-icon style, " <>
          "one character, centred, head and shoulders, simple bold shapes, white outline, and a background split " <>
          "horizontally: hot pink #{@pink} top half, deep violet #{@violet} bottom half. " <>
          "No text, no letters, no words, no watermark. Keep everything important inside the central circle."
    end
  end

  defp draw(key, prompt) do
    body = Jason.encode!(%{prompt: prompt, size: "1024x1024"})

    case Client.post("/v1/images", key, body, receive_timeout: 180_000) do
      {:ok, 200, _headers, resp} ->
        with {:ok, %{"image" => %{"b64" => b64}}} <- Jason.decode(resp),
             {:ok, bytes} <- Base.decode64(b64) do
          {:ok, bytes}
        else
          _ -> {:error, :bad_image_reply}
        end

      {:ok, status, _headers, resp} ->
        {:error, {:ruoc, status, String.slice(to_string(resp), 0, 200)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Telegram takes a static profile photo as JPEG only; ruoc returns whatever
  # the model made (PNG, WebP, JPEG). ffmpeg reads any of them.
  @doc false
  def to_jpeg(bytes) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "druzhok-avatar-" <> Base.encode16(:crypto.strong_rand_bytes(6))
      )

    File.mkdir_p!(dir)
    src = Path.join(dir, "in")
    dst = Path.join(dir, "avatar.jpg")

    try do
      File.write!(src, bytes)

      args = [
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        src,
        "-vf",
        "scale=640:640",
        "-q:v",
        "3",
        dst
      ]

      case System.cmd(ffmpeg(), args, stderr_to_stdout: true) do
        {_, 0} -> File.read(dst)
        {out, code} -> {:error, {:ffmpeg, code, String.slice(out, 0, 200)}}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp ffmpeg, do: System.find_executable("ffmpeg") || "/usr/bin/ffmpeg"

  defp short(reason), do: reason |> inspect() |> String.slice(0, 300)
end
