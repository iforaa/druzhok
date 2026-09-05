defmodule Druzhok.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # Add error logger backend to capture errors into crash_logs table
    :logger.add_handler(:druzhok_error_logger, Druzhok.ErrorLogger, %{level: :error})

    children = [
      Druzhok.Repo,
      {Registry, keys: :unique, name: Druzhok.Registry},
      {DynamicSupervisor, name: Druzhok.Host.ProcessSup, strategy: :one_for_one},
      {Finch, name: Druzhok.Finch},
      {Finch, name: Druzhok.LocalFinch},
      Druzhok.HealthMonitor,
      Druzhok.ManagerBot
    ]

    opts = [strategy: :one_for_one, name: Druzhok.Supervisor]
    Supervisor.start_link(children, opts)
  end

end
