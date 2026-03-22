defmodule Druzhok.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Druzhok.Repo,
      {Registry, keys: :unique, name: Druzhok.Registry},
      {DynamicSupervisor, name: Druzhok.InstanceDynSup, strategy: :one_for_one},
      Druzhok.InstanceWatcher,
      Supervisor.child_spec({Task, fn -> restore_instances() end}, restart: :temporary),
    ]

    opts = [strategy: :one_for_one, name: Druzhok.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp restore_instances do
    # Small delay to ensure all services are up
    Process.sleep(1_000)

    import Ecto.Query
    instances = Druzhok.Repo.all(from i in Druzhok.Instance, where: i.active == true)

    for inst <- instances do
      case Druzhok.InstanceManager.create(inst.name, %{
        workspace: inst.workspace,
        model: inst.model,
        telegram_token: inst.telegram_token,
        heartbeat_interval: inst.heartbeat_interval || 0,
        sandbox: inst.sandbox || "local",
      }) do
        {:ok, _} ->
          require Logger
          Logger.info("Restored instance: #{inst.name}")
        {:error, reason} ->
          require Logger
          Logger.error("Failed to restore instance #{inst.name}: #{inspect(reason)}")
      end
    end
  end
end
