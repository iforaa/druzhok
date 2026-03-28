defmodule Druzhok.Runtime.ZeroClaw do
  @behaviour Druzhok.Runtime

  @impl true
  def env_vars(instance) do
    port = 19000 + (Map.get(instance, :id, 0) || 0)
    %{
      "ZEROCLAW_MODEL" => Map.get(instance, :model, "default") || "default",
      "ZEROCLAW_PROVIDER" => "custom:http://host.docker.internal:4000/v1",
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
  def supports_feature?(:pairing), do: true
  def supports_feature?(:hot_reload_config), do: false
  def supports_feature?(_), do: false
end
