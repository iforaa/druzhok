defmodule Druzhok.Avatar do
  @moduledoc """
  A new bot's own face: right after the superbot reports «Бот создан», a
  picture is drawn through ruoc (`POST /v1/images`, under the bot's own key,
  so it is one picture on the bot's plan), turned into a 640×640 JPEG by
  ffmpeg and set with the bot's token (`setMyProfilePhoto`). It never blocks
  or fails creation: any step that fails is logged and the bot keeps
  Telegram's letter avatar. Off in tests (`config :druzhok, :bot_avatars`).
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
         {:ok, image} <- draw(key, prompt(inst)),
         {:ok, jpeg} <- to_jpeg(image),
         {:ok, true} <- API.set_my_profile_photo(token, jpeg) do
      Logger.info("[avatar] #{name}: set")
      :ok
    else
      nil -> Logger.warning("[avatar] #{name}: no bot or no keys")
      %Instance{} -> Logger.warning("[avatar] #{name}: no bot or no keys")
      {:error, reason} -> Logger.warning("[avatar] #{name}: #{short(reason)}")
      other -> Logger.warning("[avatar] #{name}: #{short(other)}")
    end
  rescue
    e -> Logger.warning("[avatar] #{name}: crashed (#{Exception.message(e)})")
  end

  @doc "The image prompt for a bot: its name and character, in Cleo colours."
  def prompt(%Instance{} = inst) do
    name = inst.display_name || inst.name
    look = Map.get(@looks, inst.soul_preset || "", "friendly and kind")

    "Flat vector app-icon style avatar of a cute cartoon character who is a personal AI helper named " <>
      "\"#{name}\": #{look}. If the name suggests an animal or a creature, draw that; otherwise a small friendly robot. " <>
      "One character, centred, head and shoulders, filling the middle of the frame, simple bold shapes, white outline. " <>
      "Background split horizontally: hot pink #{@pink} top half, deep violet #{@violet} bottom half. " <>
      "No text, no letters, no words, no watermark. Keep everything important inside the central circle."
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
