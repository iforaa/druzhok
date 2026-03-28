defmodule Druzhok.Runtime.PicoClaw do
  @behaviour Druzhok.Runtime

  @impl true
  def env_vars(instance) do
    port = 19000 + (Map.get(instance, :id, 0) || 0)
    env = %{
      "PICOCLAW_AGENTS_DEFAULTS_MODEL_NAME" => Map.get(instance, :model, "default") || "default",
      "PICOCLAW_GATEWAY_PORT" => to_string(port),
      "PICOCLAW_HOME" => "/data",
    }

    token = Map.get(instance, :telegram_token)
    if token do
      allowed = Map.get(instance, :allowed_users, []) || []
      Map.merge(env, %{
        "PICOCLAW_CHANNELS_TELEGRAM_ENABLED" => "true",
        "PICOCLAW_CHANNELS_TELEGRAM_TOKEN" => token,
        "PICOCLAW_CHANNELS_TELEGRAM_ALLOW_FROM" => Jason.encode!(allowed),
      })
    else
      env
    end
  end

  @impl true
  def workspace_files(_instance), do: []

  @impl true
  def clear_sessions(data_root) do
    sessions_dir = Path.join([data_root, "workspace", "sessions"])
    if File.dir?(sessions_dir), do: File.rm_rf!(sessions_dir)
    File.mkdir_p!(sessions_dir)
    :ok
  end

  @impl true
  def read_allowed_users(data_root) do
    path = Path.join(data_root, ".allowed_users.json")
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end
      {:error, _} -> []
    end
  end

  @impl true
  def add_allowed_user(data_root, user_id) do
    current = read_allowed_users(data_root)
    if user_id in current do
      :ok
    else
      updated = current ++ [user_id]
      File.write!(Path.join(data_root, ".allowed_users.json"), Jason.encode!(updated))
      :ok
    end
  end

  @impl true
  def remove_allowed_user(data_root, user_id) do
    current = read_allowed_users(data_root)
    updated = Enum.reject(current, &(&1 == user_id))
    File.write!(Path.join(data_root, ".allowed_users.json"), Jason.encode!(updated))
    :ok
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
end
