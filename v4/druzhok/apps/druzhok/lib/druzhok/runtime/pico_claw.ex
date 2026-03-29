defmodule Druzhok.Runtime.PicoClaw do
  @behaviour Druzhok.Runtime
  require Logger

  @impl true
  def env_vars(instance) do
    port = gateway_port(instance)
    %{
      "PICOCLAW_HOME" => "/data",
      "PICOCLAW_GATEWAY_PORT" => to_string(port),
      "PICOCLAW_GATEWAY_HOST" => "0.0.0.0",
    }
  end

  @impl true
  def workspace_files(instance) do
    on_demand_model = Map.get(instance, :on_demand_model)
    language = Map.get(instance, :language, "ru")
    model = Map.get(instance, :model, "default") || "default"
    port = gateway_port(instance)

    # Minimal config.json with just the gateway port to avoid port conflicts.
    # Full config (models, channels, tools) is applied via API in post_start.
    bootstrap = %{
      "version" => 1,
      "gateway" => %{"host" => "0.0.0.0", "port" => port}
    }

    files = [{"config.json", Jason.encode!(bootstrap, pretty: true)}]

    if on_demand_model do
      [{"workspace/TOOLS.md", orchestrator_tools_section(model, on_demand_model, language)} | files]
    else
      files
    end
  end

  @impl true
  def post_start(instance) do
    port = gateway_port(instance)
    base = "http://127.0.0.1:#{port}"
    data_root = Path.dirname(instance.workspace)

    with :ok <- wait_for_health(base),
         :ok <- write_full_config(data_root, instance),
         :ok <- reload(base) do
      Logger.info("PicoClaw post_start complete for #{instance.name}")
      :ok
    end
  end

  @impl true
  def parse_log_rejection(line) do
    case Regex.run(~r/rejected by allowlist.*user_id=(\S+)/, line) do
      [_, user_id] -> {:rejected, user_id}
      _ -> :ignore
    end
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
          {:ok, config} -> get_in(config, ["channels", "telegram", "allow_from"]) || []
          _ -> []
        end
      {:error, _} -> []
    end
  end

  @impl true
  def add_allowed_user(data_root, user_id) do
    update_allowed_users_via_api(data_root, fn current ->
      if user_id in current, do: current, else: current ++ [user_id]
    end)
  end

  @impl true
  def remove_allowed_user(data_root, user_id) do
    update_allowed_users_via_api(data_root, fn current ->
      Enum.reject(current, &(&1 == user_id))
    end)
  end

  @impl true
  def docker_image, do: System.get_env("PICOCLAW_IMAGE") || "picoclaw:latest"

  @impl true
  def gateway_command, do: ["gateway", "--allow-empty"]

  @impl true
  def health_path, do: "/health"

  @impl true
  def health_port, do: 18790

  @impl true
  def supports_feature?(:pairing), do: false
  def supports_feature?(_), do: false

  defp gateway_port(instance), do: 19000 + (Map.get(instance, :id, 0) || 0)

  defp wait_for_health(base, retries \\ 30) do
    url = "#{base}/health"
    case Finch.build(:get, url) |> Finch.request(Druzhok.LocalFinch) do
      {:ok, %{status: 200}} -> :ok
      _ when retries > 0 ->
        Process.sleep(1_000)
        wait_for_health(base, retries - 1)
      _ -> {:error, :health_timeout}
    end
  end

  defp write_full_config(data_root, instance) do
    config = build_full_config(instance)
    path = Path.join(data_root, "config.json")
    File.write(path, Jason.encode!(config, pretty: true))
  end

  defp reload(base) do
    case Finch.build(:post, "#{base}/reload", [], "") |> Finch.request(Druzhok.LocalFinch) do
      {:ok, %{status: 200}} -> :ok
      {:ok, resp} -> {:error, {:reload_failed, resp.status, resp.body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_full_config(instance) do
    token = Map.get(instance, :telegram_token)
    model = Map.get(instance, :model, "default") || "default"
    on_demand_model = Map.get(instance, :on_demand_model)
    mention_only = Map.get(instance, :mention_only, false)
    tenant_key = Map.get(instance, :tenant_key, "")
    port = gateway_port(instance)
    workspace = Map.get(instance, :workspace, "")
    data_root = if workspace != "", do: Path.dirname(workspace), else: ""

    existing_users = if data_root != "", do: read_allowed_users(data_root), else: []
    owner_id = Map.get(instance, :owner_telegram_id)
    all_allowed = if owner_id, do: [to_string(owner_id) | existing_users], else: existing_users
    all_allowed = Enum.uniq(all_allowed) |> Enum.reject(&(&1 == ""))
    # PicoClaw treats empty allow_from as "allow everyone" — block by default
    all_allowed = if all_allowed == [], do: ["__closed__"], else: all_allowed

    # PicoClaw uses protocol/model format — use "openai/" since our proxy is OpenAI-compatible
    models = [
      %{"model_name" => "default", "model" => "openai/#{model}",
        "api_base" => "http://#{proxy_host()}:4000/v1", "api_keys" => [tenant_key]}
    ]

    models = if on_demand_model do
      models ++ [%{"model_name" => "smart", "model" => "openai/#{on_demand_model}",
                    "api_base" => "http://#{proxy_host()}:4000/v1", "api_keys" => [tenant_key]}]
    else
      models
    end

    config = %{
      "version" => 1,
      "agents" => %{
        "defaults" => %{
          "model_name" => "default",
          "workspace" => "/data/workspace",
          "max_tokens" => 8192,
          "max_tool_iterations" => 20
        }
      },
      "model_list" => models,
      "gateway" => %{"host" => "0.0.0.0", "port" => port},
      "tools" => %{
        "exec" => %{"enabled" => true, "enable_deny_patterns" => false, "allow_remote" => true},
        "read_file" => %{"enabled" => true},
        "write_file" => %{"enabled" => true},
        "edit_file" => %{"enabled" => true},
        "append_file" => %{"enabled" => true},
        "list_dir" => %{"enabled" => true},
        "message" => %{"enabled" => true},
        "send_file" => %{"enabled" => true},
        "spawn" => %{"enabled" => true},
        "subagent" => %{"enabled" => true},
        "web_fetch" => %{"enabled" => true},
        "find_skills" => %{"enabled" => true},
        "install_skill" => %{"enabled" => true},
        "web" => %{"enabled" => true, "duckduckgo" => %{"enabled" => true, "max_results" => 5}},
        "cron" => %{"enabled" => true},
        "skills" => %{"enabled" => true}
      },
      "heartbeat" => %{"enabled" => true, "interval" => 30}
    }

    if token do
      telegram = %{"enabled" => true, "token" => token, "allow_from" => all_allowed}
      telegram = if mention_only, do: Map.put(telegram, "group_trigger", %{"mention_only" => true}), else: telegram
      Map.put(config, "channels", %{"telegram" => telegram})
    else
      config
    end
  end

  defp proxy_host, do: Druzhok.Runtime.proxy_host()

  defp update_allowed_users_via_api(data_root, update_fn) do
    config_path = Path.join(data_root, "config.json")
    with {:ok, content} <- File.read(config_path),
         {:ok, config} <- Jason.decode(content) do
      current = get_in(config, ["channels", "telegram", "allow_from"]) || []
      updated = update_fn.(current)
      config = put_in(config, ["channels", "telegram", "allow_from"], updated)
      File.write!(config_path, Jason.encode!(config, pretty: true))

      # Reload if container is running
      instance_name = Path.basename(data_root)
      case Druzhok.Repo.get_by(Druzhok.Instance, name: instance_name) do
        nil -> :ok
        instance -> reload("http://127.0.0.1:#{gateway_port(instance)}")
      end
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
