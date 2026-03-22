defmodule Druzhok.Instance.Sup do
  @moduledoc """
  Per-instance Supervisor. Starts Telegram, SessionSup (DynamicSupervisor),
  and Scheduler as supervised children, all registered in Druzhok.Registry.
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

    on_delta = fn chunk, chat_id ->
      case Registry.lookup(Druzhok.Registry, {name, :telegram}) do
        [{pid, _}] -> send(pid, {:pi_delta, chunk, chat_id})
        [] -> :ok
      end
    end

    on_event = fn event ->
      Druzhok.Events.broadcast(name, event)
    end

    send_file_fn = fn file_path, caption ->
      case Registry.lookup(Druzhok.Registry, {name, :telegram}) do
        [{pid, _}] ->
          chat_id = GenServer.call(pid, :get_chat_id, 5_000)
          if chat_id do
            Druzhok.Telegram.API.send_document(config.token, chat_id, file_path, %{caption: caption})
          else
            {:error, "No active chat"}
          end
        [] -> {:error, "Telegram not available"}
      end
    end

    # Store session config in persistent_term for SessionSup.start_session
    :persistent_term.put({:druzhok_session_config, name}, %{
      workspace: config.workspace,
      model: config.model,
      provider: config[:provider],
      api_url: config.api_url,
      api_key: config.api_key,
      instance_name: name,
      on_delta: on_delta,
      on_event: on_event,
      extra_tool_context: %{send_file_fn: send_file_fn},
    })

    children = [
      {Druzhok.Agent.Telegram, %{
        token: config.token,
        instance_name: name,
        registry_name: {:via, Registry, {Druzhok.Registry, {name, :telegram}}},
      }},
      {Druzhok.Instance.SessionSup, %{
        registry_name: {:via, Registry, {Druzhok.Registry, {name, :session_sup}}},
      }},
      {Druzhok.Scheduler, %{
        instance_name: name,
        workspace: config.workspace,
        heartbeat_interval: config.heartbeat_interval,
        registry_name: {:via, Registry, {Druzhok.Registry, {name, :scheduler}}},
      }},
    ]

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 60)
  end
end
