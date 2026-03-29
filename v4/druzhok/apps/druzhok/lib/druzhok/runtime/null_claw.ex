defmodule Druzhok.Runtime.NullClaw do
  @behaviour Druzhok.Runtime
  require Logger

  @impl true
  def env_vars(instance) do
    port = gateway_port(instance)
    %{
      "NULLCLAW_HOME" => "/data",
      "NULLCLAW_WORKSPACE" => "/data/workspace",
      "NULLCLAW_GATEWAY_PORT" => to_string(port),
    }
  end

  @impl true
  def workspace_files(instance) do
    on_demand_model = Map.get(instance, :on_demand_model)
    language = Map.get(instance, :language, "ru")
    model = Map.get(instance, :model, "default") || "default"

    # Write full config upfront — NullClaw reads config.json at startup, no hot reload
    config = build_full_config(instance)
    files = [{"config.json", Jason.encode!(config, pretty: true)}]

    if on_demand_model do
      [{"workspace/TOOLS.md", orchestrator_tools_section(model, on_demand_model, language)} | files]
    else
      files
    end
  end

  @impl true
  def post_start(_instance), do: :ok

  @rejection_pattern ~r/ignoring message from unauthorized user.*user_id=(\S+)/

  @impl true
  def parse_log_rejection(line) do
    case Regex.run(@rejection_pattern, line) do
      [_, user_id] when user_id != "unknown" -> {:rejected, user_id}
      _ -> :ignore
    end
  end

  @impl true
  def clear_sessions(data_root) do
    sessions_dir = Path.join(data_root, "sessions")
    if File.dir?(sessions_dir) do
      File.rm_rf!(sessions_dir)
      File.mkdir_p!(sessions_dir)
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
            get_in(config, ["channels", "telegram", "accounts", "main", "allow_from"]) || []
          _ -> []
        end
      {:error, _} -> []
    end
  end

  @impl true
  def add_allowed_user(data_root, user_id) do
    modify_config(data_root, fn config ->
      current = get_in(config, ["channels", "telegram", "accounts", "main", "allow_from"]) || []
      if user_id in current do
        config
      else
        put_in(config, ["channels", "telegram", "accounts", "main", "allow_from"], current ++ [user_id])
      end
    end)
  end

  @impl true
  def remove_allowed_user(data_root, user_id) do
    modify_config(data_root, fn config ->
      current = get_in(config, ["channels", "telegram", "accounts", "main", "allow_from"]) || []
      put_in(config, ["channels", "telegram", "accounts", "main", "allow_from"],
        Enum.reject(current, &(&1 == user_id)))
    end)
  end

  @impl true
  def docker_image, do: System.get_env("NULLCLAW_IMAGE") || "nullclaw:latest"

  @impl true
  def gateway_command, do: ["gateway", "--host", "::"]

  @impl true
  def health_path, do: "/health"

  @impl true
  def health_port, do: 3000

  @impl true
  def supports_feature?(:pairing), do: true
  def supports_feature?(_), do: false

  defp gateway_port(instance), do: 3000 + (Map.get(instance, :id, 0) || 0)

  defp build_full_config(instance) do
    token = Map.get(instance, :telegram_token)
    model = Map.get(instance, :model, "default") || "default"
    tenant_key = Map.get(instance, :tenant_key, "")
    port = gateway_port(instance)
    workspace = Map.get(instance, :workspace, "")
    data_root = if workspace != "", do: Path.dirname(workspace), else: ""

    existing_users = if data_root != "", do: read_allowed_users(data_root), else: []
    owner_id = Map.get(instance, :owner_telegram_id)
    all_allowed = if owner_id, do: [to_string(owner_id) | existing_users], else: existing_users
    all_allowed = Enum.uniq(all_allowed) |> Enum.reject(&(&1 == ""))

    config = %{
      "agents" => %{
        "defaults" => %{
          "model" => %{"primary" => "druzhok/#{model}"}
        }
      },
      "models" => %{
        "providers" => %{
          "druzhok" => %{
            "api_key" => tenant_key,
            "base_url" => "http://#{proxy_host()}:4000/v1"
          }
        }
      },
      "gateway" => %{
        "port" => port,
        "host" => "::",
        "require_pairing" => true,
        "allow_public_bind" => true
      },
      "autonomy" => %{
        "level" => "full",
        "workspace_only" => false
      }
    }

    if token do
      Map.put(config, "channels", %{
        "telegram" => %{
          "accounts" => %{
            "main" => %{
              "bot_token" => token,
              "allow_from" => all_allowed
            }
          }
        }
      })
    else
      config
    end
  end

  defp proxy_host, do: Druzhok.Runtime.proxy_host()

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
