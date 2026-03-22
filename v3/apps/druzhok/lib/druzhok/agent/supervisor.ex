defmodule Druzhok.Agent.Supervisor do
  @moduledoc """
  Per-user supervision tree. Starts a PiCore.Session and a Telegram bot.
  If either crashes, both restart.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: via(opts.name))
  end

  def init(opts) do
    telegram_pid = self()

    children = [
      {PiCore.Session, %{
        workspace: opts.workspace,
        model: opts.model,
        api_url: opts.api_url,
        api_key: opts.api_key,
        workspace_loader: opts[:workspace_loader],
        tools: opts[:tools],
        caller: nil  # will be set after telegram starts
      }},
    ]

    # We need a two-phase start: session first, then telegram with session PID
    # Use :rest_for_one strategy so telegram restarts if session crashes
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp via(name), do: {:via, Registry, {Druzhok.Registry, {:agent, name}}}
end
