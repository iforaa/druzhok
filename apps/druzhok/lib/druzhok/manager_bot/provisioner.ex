defmodule Druzhok.ManagerBot.Provisioner do
  @moduledoc """
  Provisioning pipeline for managed bots.

  Called by ManagerBot GenServer when a `managed_bot` update arrives.
  Handles: token retrieval → instance creation → SOUL.md (identity) write.
  """

  require Logger

  alias Druzhok.{BotManager, Instance, ModelCatalog, Repo}
  alias Druzhok.Telegram.API

  @doc """
  Run the full provisioning pipeline.

  Returns {:ok, instance_name, bot_username} or {:error, reason}.
  """
  def provision(manager_token, bot_user_id, bot_username, session) do
    with {:ok, token} <- fetch_token(manager_token, bot_user_id),
         instance_name = derive_instance_name(bot_username),
         opts = build_create_opts(%{
           token: token,
           model: ModelCatalog.default_model(),
           owner_id: session[:owner_id],
           language: session[:language] || "ru"
         }),
         {:ok, _result} <- BotManager.create(instance_name, opts) do
      # The owner is already in the allowlist via owner_telegram_id (see
      # runtime/hermes.ex build_allowlist/1), so no auto-pair + restart is
      # needed. SOUL.md is read fresh per prompt-build, so writing it now —
      # seconds after create, minutes before the bot finishes booting — is
      # picked up on the owner's first message.
      write_soul(instance_name, session[:name])
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

  def build_create_opts(params) do
    %{
      telegram_token: params[:token],
      model: params[:model] || ModelCatalog.default_model(),
      owner_telegram_id: params[:owner_id],
      language: params[:language] || "ru",
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
end
