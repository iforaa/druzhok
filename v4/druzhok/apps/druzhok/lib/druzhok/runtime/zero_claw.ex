defmodule Druzhok.Runtime.ZeroClaw do
  @behaviour Druzhok.Runtime

  @impl true
  def env_vars(instance) do
    port = 19000 + (Map.get(instance, :id, 0) || 0)
    %{
      "ZEROCLAW_MODEL" => Map.get(instance, :model, "default") || "default",
      "ZEROCLAW_PROVIDER" => "custom:http://#{proxy_host()}:4000/v1",
      "ZEROCLAW_GATEWAY_PORT" => to_string(port),
      "ZEROCLAW_CONFIG_DIR" => "/data/.zeroclaw",
      "ZEROCLAW_WORKSPACE" => "/data/workspace",
    }
  end

  @impl true
  def workspace_files(instance) do
    token = Map.get(instance, :telegram_token)
    on_demand_model = Map.get(instance, :on_demand_model)
    language = Map.get(instance, :language, "ru")
    workspace = Map.get(instance, :workspace, "")
    data_root = if workspace != "", do: Path.dirname(workspace), else: ""

    files = []

    # Merge owner ID with existing approved users from config.toml
    existing_users = if data_root != "", do: read_allowed_users(data_root), else: []
    owner_id = Map.get(instance, :owner_telegram_id)
    all_allowed = existing_users
    all_allowed = if owner_id, do: [to_string(owner_id) | all_allowed], else: all_allowed
    all_allowed = Enum.uniq(all_allowed) |> Enum.reject(&(&1 == ""))

    files = if token do
      allowed_toml = Enum.map_join(all_allowed, ", ", &"\"#{&1}\"")

      model_routes = if on_demand_model do
        """

        [[model_routes]]
        hint = "smart"
        provider = "custom:http://#{proxy_host()}:4000/v1"
        model = "#{on_demand_model}"
        """
      else
        ""
      end

      toml = """
      [autonomy]
      level = "full"
      allowed_commands = ["*"]
      block_high_risk_commands = false

      [channels_config.telegram]
      bot_token = "#{token}"
      allowed_users = [#{allowed_toml}]
      mention_only = #{Map.get(instance, :mention_only, false)}
      #{model_routes}
      """
      # Write to .zeroclaw/config.toml (ZeroClaw's config dir)
      [{".zeroclaw/config.toml", toml} | files]
    else
      files
    end

    # TOOLS.md with orchestrator model info (written to workspace dir)
    files = if on_demand_model do
      default_model = Map.get(instance, :model, "default")
      tools_content = orchestrator_tools_section(default_model, on_demand_model, language)
      [{"workspace/TOOLS.md", tools_content} | files]
    else
      files
    end

    files
  end

  @rejection_pattern ~r/ignoring message from unauthorized user.*sender_id=(\S+)/

  @impl true
  def parse_log_rejection(line) do
    case Regex.run(@rejection_pattern, line) do
      [_, sender_id] when sender_id != "unknown" -> {:rejected, sender_id}
      _ -> :ignore
    end
  end

  @impl true
  def clear_sessions(data_root) do
    sessions_db = Path.join([data_root, "workspace", "sessions", "sessions.db"])
    File.rm(sessions_db)
    File.rm(sessions_db <> "-shm")
    File.rm(sessions_db <> "-wal")
    :ok
  end

  @impl true
  def read_allowed_users(data_root) do
    case File.read(config_path(data_root)) do
      {:ok, content} -> parse_allowed_users(content)
      {:error, _} -> []
    end
  end

  @impl true
  def add_allowed_user(data_root, user_id) do
    modify_allowed_users(data_root, fn current ->
      if user_id in current, do: current, else: current ++ [user_id]
    end)
  end

  @impl true
  def remove_allowed_user(data_root, user_id) do
    modify_allowed_users(data_root, fn current ->
      Enum.reject(current, &(&1 == user_id))
    end)
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

    Для переключения используй `model_switch` с `action: "set"`, `provider: "openrouter"`, `model: "#{on_demand_model}"`.
    После выполнения запроса на умной модели — переключись обратно: `model_switch` с `provider: "openrouter"`, `model: "#{default_model}"`.
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

    To switch, use `model_switch` with `action: "set"`, `provider: "openrouter"`, `model: "#{on_demand_model}"`.
    After completing the request — switch back: `model_switch` with `provider: "openrouter"`, `model: "#{default_model}"`.
    Never switch to smart model on your own without explicit user request.
    """
  end

  defp proxy_host, do: Druzhok.Runtime.proxy_host()

  defp config_path(data_root), do: Path.join([data_root, ".zeroclaw", "config.toml"])

  defp modify_allowed_users(data_root, update_fn) do
    path = config_path(data_root)
    case File.read(path) do
      {:ok, content} ->
        updated = content |> parse_allowed_users() |> update_fn.()
        File.write(path, replace_allowed_users(content, updated))
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_allowed_users(toml_content) do
    case Regex.run(~r/allowed_users\s*=\s*\[(.*?)\]/s, toml_content) do
      [_, inner] ->
        Regex.scan(~r/"([^"]*)"/, inner)
        |> Enum.map(fn [_, id] -> id end)
        |> Enum.reject(&(&1 == ""))
      nil -> []
    end
  end

  defp replace_allowed_users(toml_content, users) do
    users_str = Enum.map_join(users, ", ", &"\"#{&1}\"")
    Regex.replace(
      ~r/allowed_users\s*=\s*\[.*?\]/s,
      toml_content,
      "allowed_users = [#{users_str}]"
    )
  end

  @doc """
  ZeroClaw volume mount: mount the tenant data root (parent of workspace),
  not just the workspace itself.
  """
  @impl true
  def docker_image, do: System.get_env("ZEROCLAW_IMAGE") || "zeroclaw:latest"

  @impl true
  def gateway_command, do: "daemon"

  @impl true
  def health_path, do: "/health"

  @impl true
  def health_port, do: 18790

  @impl true
  def post_start(_instance), do: :ok

  @impl true
  def supports_feature?(:pairing), do: true
  def supports_feature?(:hot_reload_config), do: false
  def supports_feature?(_), do: false
end
