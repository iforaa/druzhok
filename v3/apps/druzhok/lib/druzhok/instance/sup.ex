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

    sandbox_fns = case config[:sandbox] do
      type when type in ["docker", "firecracker"] ->
        mod = Druzhok.Sandbox.impl(type)
        %{
          exec: fn command -> mod.exec(name, command) end,
          read_file: fn path -> mod.read_file(name, path) end,
          write_file: fn path, content -> mod.write_file(name, path, content) end,
          list_dir: fn path -> mod.list_dir(name, path) end,
        }
      _ -> nil
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
      timezone: config[:timezone] || "UTC",
      extra_tool_context: %{send_file_fn: send_file_fn, sandbox: sandbox_fns, embedding_cache: Druzhok.EmbeddingCache},
      model_info_fn: fn action, model_name ->
        case action do
          :context_window -> Druzhok.ModelInfo.context_window(model_name)
          :supports_reasoning -> Druzhok.ModelInfo.supports_reasoning?(model_name)
          :supports_tools -> Druzhok.ModelInfo.supports_tools?(model_name)
        end
      end,
    })

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
    ] ++ sandbox_children

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 60)
  end
end
