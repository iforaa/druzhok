defmodule Druzhok.ManagerBot.Provisioner do
  @moduledoc """
  Provisioning pipeline for managed bots.

  Called by ManagerBot GenServer when a `managed_bot` update arrives.
  Handles: token retrieval → instance creation → personality application → auto-pairing.
  """

  require Logger

  alias Druzhok.{BotManager, Instance, Repo}
  alias Druzhok.Telegram.API

  @default_model "xiaomi/mimo-v2-pro"

  @hermes_personalities ~w(helpful kawaii pirate noir philosopher shakespeare surfer hype concise technical creative teacher catgirl uwu)

  @doc """
  Run the full provisioning pipeline.

  Returns {:ok, instance_name, bot_username} or {:error, reason}.
  """
  def provision(manager_token, bot_user_id, bot_username, session) do
    with {:ok, token} <- fetch_token(manager_token, bot_user_id),
         instance_name = derive_instance_name(bot_username),
         opts = build_create_opts(%{
           token: token,
           model: @default_model,
           owner_id: session[:owner_id],
           language: session[:language] || "ru",
           bot_runtime: "hermes"
         }),
         {:ok, _result} <- BotManager.create(instance_name, opts) do
      apply_personality(instance_name, session[:personality])
      write_soul(instance_name, session[:name])
      auto_pair_owner(instance_name, session[:owner_id])
      # Restart so the container picks up the updated allowlist env var
      # (BotManager.create already started it, but owner wasn't in the
      # allowlist at that point because save_to_db runs before auto_pair).
      BotManager.restart(instance_name)
      {:ok, instance_name, bot_username}
    else
      {:error, reason} ->
        Logger.error("Provisioning failed for @#{bot_username}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def derive_instance_name(bot_username) do
    bot_username
    |> String.replace_suffix("_bot", "")
    |> String.replace_suffix("Bot", "")
  end

  def personality_to_soul(key) when key in @hermes_personalities, do: {:builtin, key}
  def personality_to_soul(_), do: nil

  def build_create_opts(params) do
    %{
      telegram_token: params[:token],
      model: params[:model] || @default_model,
      owner_telegram_id: params[:owner_id],
      language: params[:language] || "ru",
      bot_runtime: params[:bot_runtime] || "hermes",
      mention_only: true,
      allow_all_telegram_users: false,
    }
  end

  # --- Private ---

  defp fetch_token(manager_token, bot_user_id) do
    case API.get_managed_bot_token(manager_token, bot_user_id) do
      {:ok, token} when is_binary(token) -> {:ok, token}
      {:ok, other} -> {:error, "unexpected token response: #{inspect(other)}"}
      {:error, reason} -> {:error, "getManagedBotToken failed: #{inspect(reason)}"}
    end
  end

  defp apply_personality(instance_name, personality) do
    case personality_to_soul(personality) do
      {:builtin, key} ->
        case Repo.get_by(Instance, name: instance_name) do
          nil -> :ok
          instance ->
            data_root = Path.dirname(instance.workspace || "")
            config_path = Path.join(data_root, "config.yaml")
            case File.read(config_path) do
              {:ok, content} ->
                line = "  personality: #{key}"
                updated = if content =~ ~r/^\s*personality:/m do
                  Regex.replace(~r/^\s*personality:.*$/m, content, line)
                else
                  content <> "\ndisplay:\n#{line}\n"
                end
                File.write!(config_path, updated)
              {:error, _} -> :ok
            end
        end
      nil -> :ok
    end
  end

  defp write_soul(instance_name, display_name) do
    case Repo.get_by(Instance, name: instance_name) do
      nil -> :ok
      instance ->
        soul_path = Path.join(Path.dirname(instance.workspace || ""), "SOUL.md")
        name = display_name || instance_name
        soul = """
        Тебя зовут #{name}. Ты персональный AI-ассистент. Ты помогаешь пользователю
        с любыми задачами: отвечаешь на вопросы, пишешь и редактируешь код, анализируешь
        информацию, выполняешь действия через инструменты. Общаешься понятно и по делу.
        """
        File.write!(soul_path, String.trim(soul))
    end
  end

  defp auto_pair_owner(instance_name, owner_id) when is_integer(owner_id) do
    case Repo.get_by(Instance, name: instance_name) do
      nil -> :ok
      instance -> Instance.add_allowed_id(instance, to_string(owner_id))
    end
  end
  defp auto_pair_owner(_, _), do: :ok
end
