defmodule ElixirClaw.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    port = String.to_integer(System.get_env("GATEWAY_PORT") || "5000")

    children = [
      {Finch, name: PiCore.Finch, pools: finch_pools()},
      {Registry, keys: :unique, name: ElixirClaw.Registry},
      {ElixirClaw.SessionManager, []},
      {Bandit, plug: ElixirClaw.Router, port: port, scheme: :http}
    ]

    opts = [strategy: :one_for_one, name: ElixirClaw.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp finch_pools do
    case System.get_env("HTTP_PROXY_URL") do
      nil -> %{}
      proxy_url ->
        uri = URI.parse(proxy_url)
        %{default: [conn_opts: [proxy: {String.to_atom(uri.scheme), uri.host, uri.port, []}]]}
    end
  end
end
