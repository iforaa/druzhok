defmodule Druzhok.BotManager do
  @moduledoc """
  Top-level API for bot container lifecycle.
  Creates, starts, stops, restarts Docker containers running bot runtimes.
  """

  alias Druzhok.{Instance, InstanceManager, TokenPool, Budget, Repo}
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
        tenant_key = Instance.generate_tenant_key(name)

        config = Map.merge(Map.new(opts), %{
          workspace: workspace,
          telegram_token: token_record.token,
          tenant_key: tenant_key,
          sandbox: "docker",
        })

        case InstanceManager.create(name, config) do
          {:ok, instance} ->
            Budget.get_or_create(instance.id)
            start(name)
            {:ok, %{name: name, model: instance.model}}

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
        runtime = Druzhok.Runtime.get(instance.bot_runtime, Druzhok.Runtime.ZeroClaw)
        env = Druzhok.Runtime.base_env(instance) |> Map.merge(runtime.env_vars(instance))
        image = runtime.docker_image()
        command = runtime.gateway_command()

        # Write runtime-specific config files to workspace
        # Write runtime-specific config files relative to tenant data root (parent of workspace)
        data_root = Path.dirname(instance.workspace)
        for {path, content} <- runtime.workspace_files(instance) do
          full_path = Path.join(data_root, path)
          File.mkdir_p!(Path.dirname(full_path))
          File.write!(full_path, content)
        end

        case start_container(name, image, env, data_root, command) do
          {:ok, container_id} ->
            Logger.info("Started bot container #{name}: #{container_id}")
            Druzhok.HealthMonitor.register(name, container_id, instance.bot_runtime || "zeroclaw")
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

  defp start_container(name, image, env, workspace, command) do
    env_args = Enum.flat_map(env, fn {k, v} -> ["-e", "#{k}=#{v}"] end)

    args = ["run", "-d",
      "--name", container_name(name),
      "--network", "host",
      "--restart", "unless-stopped",
      "-v", "#{workspace}:/data",
    ] ++ env_args ++ [image, command]

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

end
