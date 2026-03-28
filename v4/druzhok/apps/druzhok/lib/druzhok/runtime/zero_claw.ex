defmodule Druzhok.Runtime.ZeroClaw do
  @behaviour Druzhok.Runtime

  @impl true
  def env_vars(instance) do
    env = %{
      "ZEROCLAW_AGENT_MODEL" => Map.get(instance, :model, "default") || "default",
      "ZEROCLAW_PROVIDER_TYPE" => "compatible",
    }

    token = Map.get(instance, :telegram_token)
    if token do
      Map.merge(env, %{
        "ZEROCLAW_CHANNELS_TELEGRAM_ENABLED" => "true",
        "ZEROCLAW_CHANNELS_TELEGRAM_TOKEN" => token,
      })
    else
      env
    end
  end

  @impl true
  def workspace_files(instance) do
    token = Map.get(instance, :telegram_token)
    allowed = Map.get(instance, :allowed_users, []) || []

    if token do
      toml = """
      [channels.telegram]
      bot_token = "#{token}"
      allowed_users = #{inspect(allowed)}
      """
      [{"config.toml", toml}]
    else
      []
    end
  end

  @impl true
  def docker_image, do: System.get_env("ZEROCLAW_IMAGE") || "zeroclaw:latest"

  @impl true
  def gateway_command, do: "gateway"

  @impl true
  def health_path, do: "/api/health"

  @impl true
  def health_port, do: 18790

  @impl true
  def supports_feature?(:pairing), do: true
  def supports_feature?(:hot_reload_config), do: true
  def supports_feature?(_), do: false
end
