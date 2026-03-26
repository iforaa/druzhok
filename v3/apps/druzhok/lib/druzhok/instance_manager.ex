defmodule Druzhok.InstanceManager do
  @moduledoc """
  Creates and manages per-user agent instances.
  Each instance = PiCore.Session + Telegram bot under Instance.Sup.
  Persists config to SQLite so instances survive restarts.
  """

  alias Druzhok.{Instance, Repo}

  def create(name, opts) do
    provider = opts[:provider] || Druzhok.Model.get_provider(opts.model)
    {api_url, api_key} = resolve_credentials(provider, opts)

    config = %{
      name: name,
      token: opts.telegram_token,
      model: opts.model,
      provider: provider_atom(provider),
      workspace: opts.workspace,
      api_url: api_url,
      api_key: api_key,
      heartbeat_interval: opts[:heartbeat_interval] || 0,
      sandbox: opts[:sandbox] || detect_sandbox(),
    }

    ensure_workspace(config.workspace)

    case DynamicSupervisor.start_child(Druzhok.InstanceDynSup, {Druzhok.Instance.Sup, config}) do
      {:ok, sup_pid} ->
        Druzhok.InstanceWatcher.watch(name, sup_pid)
        save_to_db(name, opts)
        {:ok, %{name: name, model: config.model}}

      {:error, {:already_started, _}} ->
        {:ok, %{name: name, model: config.model}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def stop(name) when is_binary(name) do
    case find_sup_pid(name) do
      nil -> :ok
      sup_pid -> DynamicSupervisor.terminate_child(Druzhok.InstanceDynSup, sup_pid)
    end
    :persistent_term.erase({:druzhok_session_config, name})
    case Repo.get_by(Instance, name: name) do
      nil -> :ok
      inst -> Repo.update(Instance.changeset(inst, %{active: false}))
    end
    :ok
  end

  def list do
    import Ecto.Query
    Repo.all(from i in Instance, where: i.active == true)
    |> Enum.map(fn inst ->
      alive = Registry.lookup(Druzhok.Registry, {inst.name, :telegram}) != []
      %{name: inst.name, model: inst.model, heartbeat_interval: inst.heartbeat_interval, sandbox: inst.sandbox || "local", alive: alive, telegram_token: inst.telegram_token, api_key: inst.api_key}
    end)
  end

  def update_model(name, model) do
    provider = Druzhok.Model.get_provider(model)
    {api_url, api_key} = resolve_credentials(provider, %{})
    model_opts = %{
      provider: provider_atom(provider),
      api_url: api_url,
      api_key: api_key,
    }

    # Update all active per-chat sessions
    Registry.select(Druzhok.Registry, [
      {{{name, :session, :_}, :"$1", :_}, [], [:"$1"]}
    ])
    |> Enum.each(fn pid -> PiCore.Session.set_model(pid, model, model_opts) end)

    # Update persistent_term config so new sessions get the updated model
    case :persistent_term.get({:druzhok_session_config, name}, nil) do
      nil -> :ok
      config ->
        :persistent_term.put({:druzhok_session_config, name}, %{config |
          model: model,
          provider: provider_atom(provider),
          api_url: api_url,
          api_key: api_key,
        })
    end

    case Repo.get_by(Instance, name: name) do
      nil -> :ok
      inst -> Repo.update(Instance.changeset(inst, %{model: model}))
    end
    :ok
  end

  def update_heartbeat(name, minutes) do
    case lookup(name, :scheduler) do
      nil -> :ok
      pid -> Druzhok.Scheduler.set_heartbeat_interval(pid, minutes)
    end
    :ok
  end

  def delete(name) do
    case Repo.get_by(Instance, name: name) do
      nil -> :ok
      inst -> Repo.delete(inst)
    end
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
        # Terminate group session if running
        case Registry.lookup(Druzhok.Registry, {instance_name, :session, chat_id}) do
          [{pid, _}] -> GenServer.stop(pid, :normal, 5_000)
          [] -> :ok
        end
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

  defp detect_sandbox do
    fc_bin = System.get_env("FIRECRACKER_BIN") || "/usr/local/bin/firecracker"
    fc_kernel = System.get_env("FIRECRACKER_KERNEL") || "/opt/firecracker/vmlinux"
    fc_rootfs = System.get_env("FIRECRACKER_ROOTFS") || "/opt/firecracker/rootfs.ext4"

    cond do
      File.exists?(fc_bin) and File.exists?(fc_kernel) and File.exists?(fc_rootfs) ->
        "firecracker"

      System.find_executable("docker") != nil ->
        case System.cmd("docker", ["image", "inspect", "druzhok-sandbox:latest"], stderr_to_stdout: true) do
          {_, 0} -> "docker"
          _ -> "local"
        end

      true ->
        "local"
    end
  end

  defp find_sup_pid(name) do
    case Registry.lookup(Druzhok.Registry, {name, :sup}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp lookup(name, role) do
    case Registry.lookup(Druzhok.Registry, {name, role}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp save_to_db(name, opts) do
    case Repo.get_by(Instance, name: name) do
      nil ->
        %Instance{}
        |> Instance.changeset(%{
          name: name,
          telegram_token: opts.telegram_token,
          model: opts.model,
          workspace: opts.workspace,
          sandbox: opts[:sandbox] || "local",
          active: true,
        })
        |> Repo.insert()

      existing ->
        existing
        |> Instance.changeset(%{
          telegram_token: opts.telegram_token,
          model: opts.model,
          workspace: opts.workspace,
          sandbox: opts[:sandbox] || "local",
          active: true,
        })
        |> Repo.update()
    end
  end

  defp resolve_credentials(provider, _opts) do
    url = Druzhok.Settings.api_url(provider)
    key = Druzhok.Settings.api_key(provider)
    {url, key}
  end

  defp provider_atom("anthropic"), do: :anthropic
  defp provider_atom("openai"), do: :openai
  defp provider_atom("openrouter"), do: :openrouter
  defp provider_atom(a) when is_atom(a), do: a
  defp provider_atom(_), do: :openai

  defp ensure_workspace(workspace) do
    unless File.exists?(workspace) do
      File.mkdir_p!(Path.dirname(workspace))
      template = find_workspace_template()
      if template do
        File.cp_r!(template, workspace)
      else
        File.mkdir_p!(workspace)
        File.mkdir_p!(Path.join(workspace, "memory"))
      end
    end
  end

  defp find_workspace_template do
    candidates = [
      System.get_env("WORKSPACE_TEMPLATE_PATH"),
      Path.join(File.cwd!(), "workspace-template"),
      Path.join([File.cwd!(), "..", "workspace-template"]) |> Path.expand()
    ]

    Enum.find(candidates, fn
      nil -> false
      path -> File.exists?(path)
    end)
  end
end
