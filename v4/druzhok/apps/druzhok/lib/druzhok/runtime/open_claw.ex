defmodule Druzhok.Runtime.OpenClaw do
  @behaviour Druzhok.Runtime
  require Logger

  @impl true
  def env_vars(instance) do
    port = gateway_port(instance)
    %{
      "OPENCLAW_STATE_DIR" => "/data",
      "OPENCLAW_CONFIG_PATH" => "/data/openclaw.json",
      "NODE_ENV" => "production",
    }
  end

  @impl true
  def workspace_files(instance) do
    on_demand_model = Map.get(instance, :on_demand_model)
    language = Map.get(instance, :language, "ru")
    model = Map.get(instance, :model, "default") || "default"
    port = gateway_port(instance)

    # Bootstrap config with just gateway bind — full config applied in post_start
    bootstrap = %{
      "gateway" => %{
        "bind" => "0.0.0.0",
        "port" => port,
        "reload" => %{"mode" => "hybrid"}
      }
    }

    files = [{"openclaw.json", Jason.encode!(bootstrap, pretty: true)}]

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
         :ok <- write_full_config(data_root, instance) do
      Logger.info("OpenClaw post_start complete for #{instance.name}")
      :ok
    end
  end

  @impl true
  def parse_log_rejection(_line), do: :ignore

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
    config_path = Path.join(data_root, "openclaw.json")
    case File.read(config_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, config} ->
            get_in(config, ["channels", "telegram", "accounts"]) |> List.wrap()
            |> Enum.flat_map(fn acc -> Map.get(acc, "dm", %{}) |> Map.get("allowFrom", []) end)
          _ -> []
        end
      {:error, _} -> []
    end
  end

  @impl true
  def add_allowed_user(data_root, user_id) do
    modify_config(data_root, fn config ->
      update_allow_from(config, fn current ->
        if user_id in current, do: current, else: current ++ [user_id]
      end)
    end)
  end

  @impl true
  def remove_allowed_user(data_root, user_id) do
    modify_config(data_root, fn config ->
      update_allow_from(config, fn current ->
        Enum.reject(current, &(&1 == user_id))
      end)
    end)
  end

  @impl true
  def docker_image, do: System.get_env("OPENCLAW_IMAGE") || "openclaw:latest"

  @impl true
  def gateway_command, do: ["node", "openclaw.mjs", "gateway", "--allow-unconfigured", "--bind", "lan"]

  @impl true
  def health_path, do: "/healthz"

  @impl true
  def health_port, do: 18789

  @impl true
  def supports_feature?(:pairing), do: true
  def supports_feature?(_), do: false

  @impl true
  def pooled?, do: true

  defp gateway_port(instance), do: 18800 + (Map.get(instance, :id, 0) || 0)

  defp wait_for_health(base, retries \\ 30) do
    url = "#{base}/healthz"
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
    path = Path.join(data_root, "openclaw.json")
    File.write(path, Jason.encode!(config, pretty: true))
  end

  defp build_full_config(instance) do
    token = Map.get(instance, :telegram_token)
    model = Map.get(instance, :model, "default") || "default"
    on_demand_model = Map.get(instance, :on_demand_model)
    tenant_key = Map.get(instance, :tenant_key, "")
    port = gateway_port(instance)
    workspace = Map.get(instance, :workspace, "")
    data_root = if workspace != "", do: Path.dirname(workspace), else: ""

    existing_users = if data_root != "", do: read_allowed_users(data_root), else: []
    owner_id = Map.get(instance, :owner_telegram_id)
    all_allowed = if owner_id, do: [to_string(owner_id) | existing_users], else: existing_users
    all_allowed = Enum.uniq(all_allowed) |> Enum.reject(&(&1 == ""))
    # OpenClaw treats empty allowFrom as "block all" in pairing mode, no sentinel needed

    # Model provider pointing to our LLM proxy
    models = %{
      "providers" => %{
        "druzhok" => %{
          "baseUrl" => "http://#{proxy_host()}:4000/v1",
          "apiKey" => tenant_key,
          "api" => "openai-completions",
          "models" => build_model_list(model, on_demand_model)
        }
      }
    }

    config = %{
      "gateway" => %{
        "bind" => "0.0.0.0",
        "port" => port,
        "reload" => %{"mode" => "hybrid"}
      },
      "models" => models,
      "agents" => %{
        "defaults" => %{
          "model" => model,
          "workspace" => "/data/workspace"
        }
      }
    }

    # Add Telegram channel
    if token do
      telegram_account = %{
        "botToken" => token,
        "dmPolicy" => "pairing",
        "dm" => %{"allowFrom" => all_allowed}
      }

      Map.put(config, "channels", %{
        "telegram" => %{
          "accounts" => [telegram_account]
        }
      })
    else
      config
    end
  end

  defp build_model_list(model, nil) do
    [%{"id" => model, "name" => model}]
  end

  defp build_model_list(model, on_demand_model) do
    [
      %{"id" => model, "name" => "default"},
      %{"id" => on_demand_model, "name" => "smart"}
    ]
  end

  defp proxy_host, do: Druzhok.Runtime.proxy_host()

  defp modify_config(data_root, update_fn) do
    config_path = Path.join(data_root, "openclaw.json")
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

  defp update_allow_from(config, update_fn) do
    accounts = get_in(config, ["channels", "telegram", "accounts"]) || []
    case accounts do
      [first | rest] ->
        current = get_in(first, ["dm", "allowFrom"]) || []
        updated = update_fn.(current)
        first = put_in(first, ["dm", "allowFrom"], updated)
        put_in(config, ["channels", "telegram", "accounts"], [first | rest])
      [] -> config
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
