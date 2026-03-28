defmodule Druzhok.Runtime.PicoClaw do
  @behaviour Druzhok.Runtime

  @impl true
  def env_vars(instance) do
    port = 19000 + (Map.get(instance, :id, 0) || 0)
    %{
      "PICOCLAW_HOME" => "/data",
      "PICOCLAW_GATEWAY_PORT" => to_string(port),
      "PICOCLAW_GATEWAY_HOST" => "0.0.0.0",
    }
  end

  @impl true
  def workspace_files(instance) do
    token = Map.get(instance, :telegram_token)
    model = Map.get(instance, :model, "default") || "default"
    on_demand_model = Map.get(instance, :on_demand_model)
    mention_only = Map.get(instance, :mention_only, false)
    language = Map.get(instance, :language, "ru")
    tenant_key = Map.get(instance, :tenant_key, "")
    port = 19000 + (Map.get(instance, :id, 0) || 0)
    workspace = Map.get(instance, :workspace, "")
    data_root = if workspace != "", do: Path.dirname(workspace), else: ""

    # Read existing allowed users from config.json
    existing_users = if data_root != "", do: read_allowed_users(data_root), else: []
    owner_id = Map.get(instance, :owner_telegram_id)
    all_allowed = if owner_id, do: [to_string(owner_id) | existing_users], else: existing_users
    all_allowed = Enum.uniq(all_allowed) |> Enum.reject(&(&1 == ""))

    # Build model_list
    models = [
      %{
        "model_name" => "default",
        "model" => model,
        "api_base" => "http://#{proxy_host()}:4000/v1",
        "api_keys" => [tenant_key]
      }
    ]

    models = if on_demand_model do
      models ++ [%{
        "model_name" => "smart",
        "model" => on_demand_model,
        "api_base" => "http://#{proxy_host()}:4000/v1",
        "api_keys" => [tenant_key]
      }]
    else
      models
    end

    # Build config
    config = %{
      "agents" => %{
        "defaults" => %{
          "model_name" => "default",
          "workspace" => "/data/workspace"
        }
      },
      "model_list" => models,
      "gateway" => %{
        "host" => "0.0.0.0",
        "port" => port
      },
      "exec" => %{
        "allow_remote" => true,
        "enable_deny_patterns" => false
      }
    }

    # Add Telegram channel if token is set
    config = if token do
      telegram_config = %{
        "enabled" => true,
        "token" => token,
        "allow_from" => all_allowed
      }
      Map.put(config, "channels", %{"telegram" => telegram_config})
    else
      config
    end

    # Add group trigger if mention_only
    config = if mention_only do
      Map.put(config, "group_trigger", %{"mention_only" => true})
    else
      config
    end

    files = [{"config.json", Jason.encode!(config, pretty: true)}]

    # TOOLS.md with model instructions (same as ZeroClaw)
    files = if on_demand_model do
      tools_content = orchestrator_tools_section(model, on_demand_model, language)
      [{"workspace/TOOLS.md", tools_content} | files]
    else
      files
    end

    files
  end

  @impl true
  def clear_sessions(data_root) do
    sessions_dir = Path.join([data_root, "workspace", "sessions"])
    if File.dir?(sessions_dir) do
      # PicoClaw stores sessions as JSONL files
      sessions_dir
      |> File.ls!()
      |> Enum.each(fn file ->
        Path.join(sessions_dir, file) |> File.rm()
      end)
    end
    :ok
  end

  @impl true
  def read_allowed_users(data_root) do
    config_path = Path.join(data_root, "config.json")
    case File.read(config_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, config} ->
            get_in(config, ["channels", "telegram", "allow_from"]) || []
          _ -> []
        end
      {:error, _} -> []
    end
  end

  @impl true
  def add_allowed_user(data_root, user_id) do
    modify_config(data_root, fn config ->
      current = get_in(config, ["channels", "telegram", "allow_from"]) || []
      if user_id in current do
        config
      else
        put_in(config, ["channels", "telegram", "allow_from"], current ++ [user_id])
      end
    end)
  end

  @impl true
  def remove_allowed_user(data_root, user_id) do
    modify_config(data_root, fn config ->
      current = get_in(config, ["channels", "telegram", "allow_from"]) || []
      updated = Enum.reject(current, &(&1 == user_id))
      put_in(config, ["channels", "telegram", "allow_from"], updated)
    end)
  end

  @impl true
  def docker_image, do: System.get_env("PICOCLAW_IMAGE") || "picoclaw:latest"

  @impl true
  def gateway_command, do: "gateway"

  @impl true
  def health_path, do: "/health"

  @impl true
  def health_port, do: 18790

  @impl true
  def supports_feature?(:pairing), do: false
  def supports_feature?(_), do: false

  # Private helpers

  defp proxy_host, do: System.get_env("LLM_PROXY_HOST") || "host.docker.internal"

  defp modify_config(data_root, update_fn) do
    config_path = Path.join(data_root, "config.json")
    case File.read(config_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, config} ->
            updated = update_fn.(config)
            File.write(config_path, Jason.encode!(updated, pretty: true))
          _ -> {:error, :invalid_json}
        end
      {:error, reason} -> {:error, reason}
    end
  end

  defp orchestrator_tools_section(default_model, on_demand_model, "ru") do
    """
    # TOOLS.md — Druzhok Orchestrator

    ## Доступные модели
    - **Быстрая (по умолчанию):** #{default_model} — используется для всех сообщений
    - **Умная (по запросу):** #{on_demand_model} — только когда пользователь явно просит

    ## Правила переключения моделей
    Используй быструю модель для всего по умолчанию. Переключайся на умную ТОЛЬКО если пользователь:
    - Говорит "подумай", "think", "используй умную модель", "/smart"
    - Явно просит сложный анализ или глубокое рассуждение

    После выполнения запроса на умной модели — переключись обратно на быструю.
    Никогда не переключайся на умную модель самостоятельно без явной просьбы пользователя.
    """
  end

  defp orchestrator_tools_section(default_model, on_demand_model, _lang) do
    """
    # TOOLS.md — Druzhok Orchestrator

    ## Available Models
    - **Fast (default):** #{default_model} — used for all messages
    - **Smart (on-demand):** #{on_demand_model} — only when user explicitly asks

    ## Model Switching Rules
    Use the fast model for everything by default. Switch to smart ONLY if the user:
    - Says "think harder", "use smart model", "/smart"
    - Explicitly asks for deep analysis or complex reasoning

    After completing the request on smart model — switch back to the fast model.
    Never switch to smart model on your own without explicit user request.
    """
  end
end
