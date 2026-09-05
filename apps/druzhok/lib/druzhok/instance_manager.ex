defmodule Druzhok.InstanceManager do
  @moduledoc """
  Creates and manages bot instances. V4 orchestrator — no in-process bot sessions.
  """

  alias Druzhok.{Instance, Repo}

  def create(name, opts) do
    config = %{
      name: name,
      workspace: opts[:workspace] || default_workspace(name),
      model: opts[:model] || "default",
      tenant_key: opts[:tenant_key] || Instance.generate_tenant_key(name),
      telegram_token: opts[:telegram_token],
      owner_telegram_id: opts[:owner_telegram_id],
      language: opts[:language] || "ru",
      mention_only: opts[:mention_only] || false,
      allow_all_telegram_users: opts[:allow_all_telegram_users] || false,
      ruoc_account_id: opts[:ruoc_account_id],
      ruoc_api_key: opts[:ruoc_api_key],
    }

    ensure_workspace(config.workspace)
    case save_to_db(name, config) do
      {:ok, instance} -> {:ok, instance}
      error -> error
    end
  end

  def stop(name) when is_binary(name) do
    case Repo.get_by(Instance, name: name) do
      nil -> :ok
      inst -> Repo.update(Instance.changeset(inst, %{active: false}))
    end
    :ok
  end

  def list do
    import Ecto.Query
    Repo.all(from i in Instance, order_by: [desc: i.active, asc: i.name])
  end

  def delete(name) do
    stop(name)
    case Repo.get_by(Instance, name: name) do
      nil -> :ok
      inst -> Repo.delete(inst)
    end
  end

  def update_model(name, model) do
    case Repo.get_by(Instance, name: name) do
      nil -> :ok
      inst -> Repo.update(Instance.changeset(inst, %{model: model}))
    end
    :ok
  end

  def approve_pairing(instance_name) do
    case Druzhok.Pairing.approve(instance_name) do
      {:ok, pairing} ->
        Druzhok.Events.broadcast(instance_name, %{type: :pairing_approved, user: pairing.display_name})
        {:ok, pairing}
      error -> error
    end
  end

  def approve_group(instance_name, chat_id) do
    case Druzhok.AllowedChat.approve(instance_name, chat_id) do
      {:ok, chat} ->
        Druzhok.Events.broadcast(instance_name, %{type: :group_approved, title: chat.title})
        {:ok, chat}
      error -> error
    end
  end

  def reject_group(instance_name, chat_id) do
    case Druzhok.AllowedChat.reject(instance_name, chat_id) do
      {:ok, chat} ->
        Druzhok.Events.broadcast(instance_name, %{type: :group_rejected, title: chat.title})
        {:ok, chat}
      error -> error
    end
  end

  def get_pairing(instance_name) do
    Druzhok.Pairing.get_pending(instance_name)
  end

  def get_groups(instance_name) do
    Druzhok.AllowedChat.groups_for_instance(instance_name)
  end

  def get_owner(instance_name) do
    case Druzhok.Repo.get_by(Druzhok.Instance, name: instance_name) do
      nil -> nil
      inst -> inst.owner_telegram_id
    end
  end

  defp default_workspace(name) do
    data_root = System.get_env("DRUZHOK_DATA_ROOT") || Path.expand("../../data", __DIR__)
    Path.join([data_root, "instances", name, "workspace"])
  end

  defp save_to_db(name, config) do
    case Repo.get_by(Instance, name: name) do
      nil ->
        %Instance{}
        |> Instance.changeset(%{
          name: name,
          telegram_token: config.telegram_token,
          model: config.model,
          workspace: config.workspace,
          tenant_key: config.tenant_key,
          language: config[:language] || "ru",
          owner_telegram_id: config[:owner_telegram_id],
          mention_only: config[:mention_only] || false,
          allow_all_telegram_users: config[:allow_all_telegram_users] || false,
          ruoc_account_id: config[:ruoc_account_id],
          ruoc_api_key: config[:ruoc_api_key],
          active: true,
        })
        |> Repo.insert()

      existing ->
        existing
        |> Instance.changeset(%{
          model: config.model,
          active: true,
        })
        |> Repo.update()
    end
  end

  # Seed files (config.yaml, AGENTS.md) come from `Runtime.workspace_files/1`
  # at start; here we only guarantee the directory exists.
  defp ensure_workspace(workspace), do: File.mkdir_p!(workspace)
end
