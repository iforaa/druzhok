defmodule Druzhok.Instance.Sup do
  @moduledoc """
  Per-instance supervisor. In v4, this manages the sandbox container
  and scheduler — no more in-process bot sessions.
  """
  use Supervisor

  def child_spec(config) do
    %{
      id: {__MODULE__, config.name},
      start: {__MODULE__, :start_link, [config]},
      restart: :temporary,
      type: :supervisor,
    }
  end

  def start_link(config) do
    name = {:via, Registry, {Druzhok.Registry, {config.name, :sup}}}
    Supervisor.start_link(__MODULE__, config, name: name)
  end

  def init(config) do
    name = config.name

    sandbox_children = case config[:sandbox] do
      "docker" ->
        [{Druzhok.Sandbox.DockerClient, %{
          instance_name: name,
          workspace: config.workspace,
          registry_name: {:via, Registry, {Druzhok.Registry, {name, :sandbox}}},
        }}]
      "firecracker" ->
        [{Druzhok.Sandbox.FirecrackerClient, %{
          instance_name: name,
          registry_name: {:via, Registry, {Druzhok.Registry, {name, :sandbox}}},
        }}]
      _ -> []
    end

    children = [
      {Druzhok.Scheduler, %{
        instance_name: name,
        workspace: config.workspace,
        heartbeat_interval: config.heartbeat_interval,
        registry_name: {:via, Registry, {Druzhok.Registry, {name, :scheduler}}},
      }},
    ] ++ sandbox_children

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 60)
  end
end
