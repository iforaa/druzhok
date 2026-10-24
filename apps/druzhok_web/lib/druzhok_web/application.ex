defmodule DruzhokWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = relay() ++ [DruzhokWebWeb.Panel.Limiter, DruzhokWebWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DruzhokWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The Telegram relay, the bot cabinet (Druzhok.Cabinet, before the
  # controller that casts to it) and the bot lifecycle controller run only where the
  # endpoint serves (druzhok.service, `mix phx.server`), never in a BEAM that
  # merely boots the app — a one-off `ops/druzhok-run.sh`, `ops/druzhok`,
  # `iex -S mix` — so there is never a second relay
  # delivering the same rows or a second controller acting on a bot. Off in
  # tests too (no server); both have their own tests in apps/druzhok.
  defp relay do
    if Phoenix.Endpoint.server?(:druzhok_web, DruzhokWebWeb.Endpoint),
      do: [Druzhok.Telegram.Relay, Druzhok.Cabinet, Druzhok.Lifecycle],
      else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DruzhokWebWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
