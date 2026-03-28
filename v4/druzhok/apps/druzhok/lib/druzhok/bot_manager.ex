defmodule Druzhok.BotManager do
  @moduledoc """
  Top-level API for bot container lifecycle.
  Creates, starts, stops, restarts Docker containers running bot runtimes.
  """

  alias Druzhok.{Instance, InstanceManager, BotConfig, TokenPool, Budget, Repo}
  require Logger

  def create(name, opts) do
    data_root = System.get_env("DRUZHOK_DATA_ROOT") || Path.expand("../../../data/tenants", __DIR__)
    workspace = Path.join([data_root, name, "workspace"])

    token_result = if opts[:telegram_token] do
      {:ok, %{token: opts[:telegram_token], id: nil}}
    else
      TokenPool.allocate(0)
    end

    case token_result do
      {:ok, token_record} ->
        tenant_key = generate_tenant_key(name)

        config = Map.merge(Map.new(opts), %{
          workspace: workspace,
          telegram_token: token_record.token,
          tenant_key: tenant_key,
          sandbox: "docker",
        })

        case InstanceManager.create(name, config) do
          {:ok, instance_info} ->
            if inst = Repo.get_by(Instance, name: name) do
              Budget.get_or_create(inst.id)
              # Reassign the temporary token allocation to the real instance
              if token_record.id != nil do
                TokenPool.release(0)
                TokenPool.allocate(inst.id)
              end
            end
            start(name)
            {:ok, instance_info}

          error -> error
        end

      {:error, :no_tokens_available} ->
        {:error, "No Telegram tokens available in pool"}
    end
  end

  def start(name) do
    case Repo.get_by(Instance, name: name) do
      nil -> {:error, :not_found}
      instance ->
        env = BotConfig.build(instance)
        image = BotConfig.docker_image(instance)

        case start_container(name, image, env, instance.workspace) do
          {:ok, container_id} ->
            Logger.info("Started bot container #{name}: #{container_id}")
            Druzhok.HealthMonitor.register(name, container_id)
            Repo.update(Instance.changeset(instance, %{active: true}))
            {:ok, container_id}

          {:error, reason} ->
            Logger.error("Failed to start bot #{name}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  def stop(name) do
    stop_container(name)
    Druzhok.HealthMonitor.unregister(name)
    case Repo.get_by(Instance, name: name) do
      nil -> :ok
      instance -> Repo.update(Instance.changeset(instance, %{active: false}))
    end
    :ok
  end

  def restart(name) do
    stop(name)
    Process.sleep(1_000)
    start(name)
  end

  def delete(name) do
    stop(name)
    case Repo.get_by(Instance, name: name) do
      nil -> :ok
      instance ->
        TokenPool.release(instance.id)
        Repo.delete(instance)
    end
    :ok
  end

  def status(name) do
    {output, exit_code} = System.cmd("docker", ["inspect", "--format", "{{.State.Status}}", container_name(name)], stderr_to_stdout: true)
    if exit_code == 0, do: String.trim(output), else: "not_found"
  end

  defp start_container(name, image, env, workspace) do
    env_args = Enum.flat_map(env, fn {k, v} -> ["-e", "#{k}=#{v}"] end)

    args = ["run", "-d",
      "--name", container_name(name),
      "--network", "host",
      "--restart", "unless-stopped",
      "-v", "#{workspace}:/data",
    ] ++ env_args ++ [image, "gateway"]

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {container_id, 0} -> {:ok, String.trim(container_id)}
      {error, _} -> {:error, String.trim(error)}
    end
  end

  defp stop_container(name) do
    System.cmd("docker", ["rm", "-f", container_name(name)], stderr_to_stdout: true)
    :ok
  end

  def container_name(name), do: "druzhok-bot-#{name}"

  defp generate_tenant_key(name) do
    random = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    "dk-#{name}-#{random}"
  end
end
