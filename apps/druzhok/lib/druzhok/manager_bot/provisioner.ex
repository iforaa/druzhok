defmodule Druzhok.ManagerBot.Provisioner do
  @moduledoc """
  Provisioning pipeline for managed bots.

  Called by ManagerBot GenServer when a `managed_bot` update arrives.
  Handles: token retrieval → instance creation (with the name the owner
  typed, from which the first start writes SOUL.md) → first start.
  """

  require Logger

  alias Druzhok.{BotManager, Ruoc}
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
           model: Ruoc.default_model(),
           owner_id: session[:owner_id],
           language: session[:language] || "ru",
           invite: session[:invite],
           display_name: session[:name]
         }),
         {:ok, _result} <- BotManager.create(instance_name, opts) do
      # The owner is already in the allowlist via owner_telegram_id (see
      # runtime/hermes.ex build_allowlist/1), so no auto-pair + restart is
      # needed. A slow or failed start is the lifecycle controller's to retry,
      # not a provisioning error. Waiting keeps the creator's "created and
      # started" message true in the common case.

      case BotManager.start(instance_name, wait: true) do
        {:ok, _} -> :ok
        other -> Logger.warning("First start of #{instance_name} not done yet: #{inspect(other)}")
      end

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
    base = %{
      telegram_token: params[:token],
      model: params[:model] || Ruoc.default_model(),
      owner_telegram_id: params[:owner_id],
      language: params[:language] || "ru",
      mention_only: true,
      allow_all_telegram_users: false,
      display_name: params[:display_name]
    }

    case params[:invite] do
      code when is_binary(code) and code != "" -> Map.put(base, :invite, code)
      _ -> base
    end
  end

  # --- Private ---

  defp fetch_token(manager_token, bot_user_id) do
    case API.get_managed_bot_token(manager_token, bot_user_id) do
      {:ok, token} when is_binary(token) -> {:ok, token}
      {:ok, other} -> {:error, "unexpected token response: #{inspect(other)}"}
      {:error, reason} -> {:error, "getManagedBotToken failed: #{inspect(reason)}"}
    end
  end
end
