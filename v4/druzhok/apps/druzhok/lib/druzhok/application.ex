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
      {DynamicSupervisor, name: Druzhok.InstanceDynSup, strategy: :one_for_one},
      {Finch, name: Druzhok.Finch, pools: finch_pools()},
      {Finch, name: Druzhok.LocalFinch},
      Druzhok.HealthMonitor,
      Druzhok.PoolManager,
    ]

    opts = [strategy: :one_for_one, name: Druzhok.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp finch_pools do
    case Application.get_env(:druzhok, :http_proxy_url) do
      nil -> %{}
      proxy_url ->
        uri = URI.parse(proxy_url)
        %{default: [conn_opts: [proxy: {String.to_atom(uri.scheme), uri.host, uri.port, []}]]}
    end
  end
end
