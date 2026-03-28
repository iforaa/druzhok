defmodule Druzhok.Runtime.ZeroClaw do
  @behaviour Druzhok.Runtime

  @impl true
  def env_vars(instance) do
    port = 19000 + (Map.get(instance, :id, 0) || 0)
    %{
      "ZEROCLAW_AGENT_MODEL" => Map.get(instance, :model, "default") || "default",
      "ZEROCLAW_PROVIDER_TYPE" => "compatible",
      "ZEROCLAW_GATEWAY_PORT" => to_string(port),
      "ZEROCLAW_CONFIG_DIR" => "/data/.zeroclaw",
      "ZEROCLAW_WORKSPACE" => "/data/workspace",
    }
  end

  @impl true
  def workspace_files(instance) do
    token = Map.get(instance, :telegram_token)
    allowed = Map.get(instance, :allowed_users, []) || []

    files = []

    # Include owner's Telegram ID in allowed_users if set
    owner_id = Map.get(instance, :owner_telegram_id)
    all_allowed = if owner_id, do: [to_string(owner_id) | allowed], else: allowed
    all_allowed = Enum.uniq(all_allowed) |> Enum.reject(&(&1 == ""))

    files = if token do
      allowed_toml = Enum.map_join(all_allowed, ", ", &"\"#{&1}\"")
      toml = """
      [channels_config.telegram]
      bot_token = "#{token}"
      allowed_users = [#{allowed_toml}]
      mention_only = false
      """
      # Write to .zeroclaw/config.toml (ZeroClaw's config dir)
      [{".zeroclaw/config.toml", toml} | files]
    else
      files
    end

    files
  end

  @impl true
  def read_allowed_users(data_root) do
    config_path = Path.join([data_root, ".zeroclaw", "config.toml"])
    case File.read(config_path) do
      {:ok, content} -> parse_allowed_users(content)
      {:error, _} -> []
    end
  end

  @impl true
  def add_allowed_user(data_root, user_id) do
    config_path = Path.join([data_root, ".zeroclaw", "config.toml"])
    case File.read(config_path) do
      {:ok, content} ->
        current = parse_allowed_users(content)
        if user_id in current do
          :ok
        else
          updated = current ++ [user_id]
          new_content = replace_allowed_users(content, updated)
          File.write!(config_path, new_content)
          :ok
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def remove_allowed_user(data_root, user_id) do
    config_path = Path.join([data_root, ".zeroclaw", "config.toml"])
    case File.read(config_path) do
      {:ok, content} ->
        current = parse_allowed_users(content)
        updated = Enum.reject(current, &(&1 == user_id))
        new_content = replace_allowed_users(content, updated)
        File.write!(config_path, new_content)
        :ok
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
  def supports_feature?(:pairing), do: true
  def supports_feature?(:hot_reload_config), do: true
  def supports_feature?(_), do: false
end
