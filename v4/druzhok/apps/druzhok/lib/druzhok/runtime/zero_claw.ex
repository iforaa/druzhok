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

    files = if token do
      allowed_toml = Enum.map_join(allowed, ", ", &"\"#{&1}\"")
      toml = """
      [channels_config.telegram]
      bot_token = "#{token}"
      allowed_users = [#{allowed_toml}]
      """
      # Write to .zeroclaw/config.toml (ZeroClaw's config dir)
      [{".zeroclaw/config.toml", toml} | files]
    else
      files
    end

    files
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
