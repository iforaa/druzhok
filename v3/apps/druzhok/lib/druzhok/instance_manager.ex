defmodule Druzhok.InstanceManager do
  @moduledoc """
  Creates and manages per-user agent instances.
  Each instance = PiCore.Session + Telegram bot under Instance.Sup.
  Persists config to SQLite so instances survive restarts.
  """

  alias Druzhok.{Instance, Repo}

  def create(name, opts) do
    config = %{
      name: name,
      token: opts.telegram_token,
      model: opts.model,
      workspace: opts.workspace,
      api_url: opts.api_url,
      api_key: opts.api_key,
      heartbeat_interval: opts[:heartbeat_interval] || 0,
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
      %{name: inst.name, model: inst.model, heartbeat_interval: inst.heartbeat_interval, alive: alive}
    end)
  end

  def update_model(name, model) do
    case lookup(name, :session) do
      nil -> :ok
      pid -> PiCore.Session.set_model(pid, model)
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
          active: true,
        })
        |> Repo.insert()

      existing ->
        existing
        |> Instance.changeset(%{
          telegram_token: opts.telegram_token,
          model: opts.model,
          workspace: opts.workspace,
          active: true,
        })
        |> Repo.update()
    end
  end

  defp ensure_workspace(workspace) do
    unless File.exists?(workspace) do
      template = Path.join([File.cwd!(), "..", "workspace-template"]) |> Path.expand()
      if File.exists?(template) do
        File.cp_r!(template, workspace)
      else
        File.mkdir_p!(workspace)
        File.mkdir_p!(Path.join(workspace, "memory"))
      end
    end
  end
end
