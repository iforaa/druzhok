defmodule Druzhok.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        Druzhok.Repo,
        {Registry, keys: :unique, name: Druzhok.Registry},
        {DynamicSupervisor, name: Druzhok.Host.ProcessSup, strategy: :one_for_one},
        {Finch, name: Druzhok.Finch},
        {Finch, name: Druzhok.LocalFinch},
        Druzhok.Fetch.Worker
      ] ++ manager_bot()

    opts = [strategy: :one_for_one, name: Druzhok.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # One getUpdates poller per token: ops/druzhok-run.sh turns this off, or its
  # one-off BEAM fights druzhok.service's ManagerBot (409 Conflict).
  defp manager_bot,
    do: if(Application.get_env(:druzhok, :manager_bot, true), do: [Druzhok.ManagerBot], else: [])
end
