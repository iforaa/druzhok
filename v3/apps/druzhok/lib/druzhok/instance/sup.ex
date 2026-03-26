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
      case event[:type] do
        :tool_call ->
          tool_name = event[:name]
          case Registry.lookup(Druzhok.Registry, {name, :telegram}) do
            [{pid, _}] -> send(pid, {:pi_tool_status, tool_name})
            [] -> :ok
          end

        :llm_done ->
          Druzhok.LlmRequest.log(%{
            instance_name: name,
            model: event[:model],
            input_tokens: event[:input_tokens] || 0,
            output_tokens: event[:output_tokens] || 0,
            tool_calls_count: event[:tool_calls_count] || 0,
            elapsed_ms: event[:elapsed_ms],
            iteration: event[:iteration],
            prompt_preview: event[:prompt_preview],
            response_preview: event[:response_preview]
          })

        :tool_exec ->
          Druzhok.ToolExecution.log(%{
            instance_name: name,
            tool_name: event[:name],
            elapsed_ms: event[:elapsed_ms],
            is_error: event[:is_error] || false,
            output_size: event[:output_size] || 0
          })

        _ -> :ok
      end
    end

    make_send_fn = fn api_fn ->
      fn payload, caption ->
        case Registry.lookup(Druzhok.Registry, {name, :telegram}) do
          [{pid, _}] ->
            chat_id = GenServer.call(pid, :get_chat_id, 5_000)
            if chat_id do
              api_fn.(config.token, chat_id, payload, %{caption: caption})
            else
              {:error, "No active chat"}
            end
          [] -> {:error, "Telegram not available"}
        end
      end
    end

    send_file_fn = make_send_fn.(&Druzhok.Telegram.API.send_document/4)
    send_photo_fn = make_send_fn.(&Druzhok.Telegram.API.send_photo/4)

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
      extra_tool_context: %{
        send_file_fn: send_file_fn,
        send_photo_fn: send_photo_fn,
        sandbox: sandbox_fns,
        embedding_cache: Druzhok.EmbeddingCache,
        embedding_api_url: Druzhok.Settings.get("embedding_api_url"),
        embedding_api_key: Druzhok.Settings.get("embedding_api_key"),
        embedding_model: Druzhok.Settings.get("embedding_model"),
        compaction_model: Druzhok.Settings.get("compaction_model"),
        compaction_api_url: Druzhok.Settings.get("compaction_api_url"),
        compaction_api_key: Druzhok.Settings.get("compaction_api_key"),
        image_generation_enabled: Druzhok.Settings.get("image_generation_enabled") == "true",
        runtime_info_fn: fn ->
          Druzhok.TokenBudget.runtime_section(name, config.model, config[:sandbox] || "local")
        end,
        prompt_guard_fn: fn -> Druzhok.PromptGuard.check(name) end,
        image_describe_fn: &Druzhok.ImageDescriber.describe/1,
        openrouter_api_key: Druzhok.Settings.api_key("openrouter"),
        openrouter_api_url: Druzhok.Settings.api_url("openrouter")
      },
      model_info_fn: fn action, model_name ->
        case action do
          :context_window -> Druzhok.ModelInfo.context_window(model_name)
          :supports_reasoning -> Druzhok.ModelInfo.supports_reasoning?(model_name)
          :supports_tools -> Druzhok.ModelInfo.supports_tools?(model_name)
          :supports_vision -> Druzhok.ModelInfo.supports_vision?(model_name)
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

    telegram_children = if config.token do
      [{Druzhok.Agent.Telegram, %{
        token: config.token,
        instance_name: name,
        registry_name: {:via, Registry, {Druzhok.Registry, {name, :telegram}}},
      }}]
    else
      []
    end

    children = telegram_children ++ [
      {Druzhok.Instance.SessionSup, %{
        registry_name: {:via, Registry, {Druzhok.Registry, {name, :session_sup}}},
      }},
      {Druzhok.Scheduler, %{
        instance_name: name,
        workspace: config.workspace,
        heartbeat_interval: config.heartbeat_interval,
        dream_hour: config[:dream_hour] || -1,
        registry_name: {:via, Registry, {Druzhok.Registry, {name, :scheduler}}},
      }},
    ] ++ sandbox_children

    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 60)
  end
end
