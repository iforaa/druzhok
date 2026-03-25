defmodule PiCore.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      finch_child()
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: PiCore.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp finch_child do
    case Application.get_env(:pi_core, :http_proxy_url) do
      nil ->
        {Finch, name: PiCore.Finch}

      url ->
        uri = URI.parse(url)
        scheme = if uri.scheme == "https", do: :https, else: :http

        {Finch,
         name: PiCore.Finch,
         pools: %{
           :default => [
             conn_opts: [
               proxy: {scheme, uri.host, uri.port, []}
             ]
           ]
         }}
    end
  end
end
