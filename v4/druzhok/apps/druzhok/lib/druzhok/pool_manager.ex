defmodule Druzhok.PoolManager do
  use GenServer
  require Logger

  alias Druzhok.{Repo, Pool, PoolConfig, HealthMonitor}

  @health_retries 180
  @status_starting "starting"
  @status_running "running"
  @status_stopped "stopped"
  @status_failed "failed"
  @verify_interval 30_000

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def assign(instance) do
    GenServer.call(__MODULE__, {:assign, instance}, 300_000)
  end

  def remove(instance) do
    GenServer.call(__MODULE__, {:remove, instance}, 300_000)
  end

  @doc "Regenerate config and restart pool container. Use for settings changes."
  def reload(instance) do
    case instance.pool_id do
      nil -> :ok
      pool_id ->
        pool = Pool.with_instances(pool_id)
        GenServer.call(__MODULE__, {:reload, pool}, 300_000)
    end
  end

  def get_pool(instance) do
    case instance.pool_id do
      nil -> nil
      pool_id -> Pool.with_instances(pool_id)
    end
  end

  def pools do
    Pool.all_with_instances()
  end

  # --- GenServer callbacks ---

  @impl true
  def init(_opts) do
    Process.send_after(self(), :verify_pools, @verify_interval)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:verify_pools, state) do
    # Check all pools that have instances, not just "active" ones —
    # a pool may have status "failed" but the container started successfully after the timeout
    for pool <- Pool.all_with_instances() do
      case container_running?(pool.container) do
        true ->
          if pool.status != @status_running do
            pool |> Ecto.Changeset.change(%{status: @status_running}) |> Repo.update!()
            Logger.info("[pool_manager] pool=#{pool.name} container is running, updated status")
          end
          HealthMonitor.register(pool.name, pool.container, "openclaw")

        false ->
          if length(pool.instances) > 0 do
            Logger.warning("[pool_manager] pool=#{pool.name} container missing, restarting")
            try do
              restart_pool_container(pool)
            rescue
              e -> Logger.error("[pool_manager] failed to restart pool=#{pool.name}: #{inspect(e)}")
            end
          end
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:assign, instance}, _from, state) do
    result = do_assign(instance)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:remove, instance}, _from, state) do
    result = do_remove(instance)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:reload, pool}, _from, state) do
    result = restart_pool_container(pool)
    {:reply, result, state}
  end

  # --- Internal ---

  defp do_assign(instance) do
    pool = Pool.pool_with_capacity() || create_pool()

    instance
    |> Ecto.Changeset.change(%{pool_id: pool.id})
    |> Repo.update!()

    pool = Pool.with_instances(pool.id)

    case restart_pool_container(pool) do
      :ok ->
        Logger.info("[pool_manager] assigned instance=#{instance.name} to pool=#{pool.name} (#{length(pool.instances)}/#{pool.max_tenants})")
        {:ok, pool}

      {:error, reason} ->
        Logger.error("[pool_manager] assign failed for instance=#{instance.name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_remove(instance) do
    pool_id = instance.pool_id

    instance
    |> Ecto.Changeset.change(%{pool_id: nil})
    |> Repo.update!()

    pool = Pool.with_instances(pool_id)

    if Enum.empty?(pool.instances) do
      stop_pool_container(pool)
      pool |> Ecto.Changeset.change(%{status: @status_stopped}) |> Repo.update!()
      HealthMonitor.unregister(pool.name)
      Logger.info("[pool_manager] stopped empty pool=#{pool.name}")
    else
      restart_pool_container(pool)
      Logger.info("[pool_manager] removed instance=#{instance.name} from pool=#{pool.name} (#{length(pool.instances)}/#{pool.max_tenants})")
    end

    :ok
  end

  defp create_pool do
    name = Pool.next_name()
    port = Pool.next_port()
    container = "druzhok-pool-#{port - 18800 + 1}"

    %Pool{}
    |> Pool.changeset(%{name: name, container: container, port: port, status: @status_starting})
    |> Repo.insert!()
  end

  defp restart_pool_container(pool) do
    stop_pool_container(pool)

    # Re-fetch to get current instance list after any membership changes
    pool = Pool.with_instances(pool.id)
    instances = pool.instances

    data_root = pool_data_root(pool)
    File.mkdir_p!(data_root)
    File.mkdir_p!(Path.join(data_root, "state"))

    config = PoolConfig.build(instances, port: pool.port)
    config_path = Path.join(data_root, "openclaw.json")
    File.write!(config_path, Jason.encode!(config, pretty: true))

    docker_args = build_docker_args(pool, instances)
    {output, exit_code} = System.cmd("docker", ["run" | docker_args], stderr_to_stdout: true)

    if exit_code != 0 do
      Logger.error("[pool_manager] docker run failed for pool=#{pool.name}: #{output}")
      pool |> Ecto.Changeset.change(%{status: @status_failed}) |> Repo.update!()
      {:error, {:docker_failed, output}}
    else
      case wait_for_health(pool) do
        :ok ->
          pool |> Ecto.Changeset.change(%{status: @status_running}) |> Repo.update!()
          HealthMonitor.register(pool.name, pool.container, "openclaw")
          :ok

        :timeout ->
          pool |> Ecto.Changeset.change(%{status: @status_failed}) |> Repo.update!()
          {:error, :health_timeout}
      end
    end
  end

  defp stop_pool_container(pool) do
    System.cmd("docker", ["rm", "-f", pool.container], stderr_to_stdout: true)
    HealthMonitor.unregister(pool.name)
  end

  defp build_docker_args(pool, instances) do
    data_root = pool_data_root(pool)
    image = System.get_env("OPENCLAW_IMAGE") || "openclaw:latest"

    # --network host works on Linux but not macOS Docker Desktop.
    # On macOS, publish ports explicitly as fallback.
    network_args = case :os.type() do
      {:unix, :linux} -> ["--network", "host"]
      _ -> ["-p", "#{pool.port}:#{pool.port}"]
    end

    # Grant access to Docker socket for sandbox mode
    docker_gid = get_docker_gid()
    group_args = if docker_gid, do: ["--group-add", docker_gid], else: []

    base_args = [
      "-d",
      "--name", pool.container,
      "--restart", "unless-stopped"
    ] ++ network_args ++ group_args ++ [
      "-v", "#{data_root}:/data",
      "-v", "/var/run/docker.sock:/var/run/docker.sock",
      "-e", "OPENCLAW_CONFIG_PATH=/data/openclaw.json",
      "-e", "OPENCLAW_STATE_DIR=/data/state",
      "-e", "NODE_OPTIONS=--max-old-space-size=512",
      "-e", "NODE_ENV=production",
      "-e", "OPENAI_API_KEY=proxy-managed",
      "-e", "OPENROUTER_API_KEY=proxy-managed"
    ]

    workspace_mounts =
      Enum.flat_map(instances, fn inst ->
        host_workspace = inst.workspace
        container_workspace = "/data/workspaces/#{inst.name}"
        ["-v", "#{host_workspace}:#{container_workspace}"]
      end)

    command = ["node", "openclaw.mjs", "gateway", "--allow-unconfigured"]

    base_args ++ workspace_mounts ++ [image | command]
  end

  defp wait_for_health(pool) do
    url = "http://127.0.0.1:#{pool.port}/healthz"

    Enum.reduce_while(1..@health_retries, nil, fn i, _ ->
      if i > 1, do: Process.sleep(1_000)

      case Finch.build(:get, url) |> Finch.request(Druzhok.LocalFinch) do
        {:ok, %{status: 200}} ->
          Logger.info("[pool_manager] pool=#{pool.name} health verified")
          {:halt, :ok}

        _ ->
          if i == @health_retries do
            Logger.error("[pool_manager] pool=#{pool.name} health check failed after #{@health_retries}s")
            {:halt, :timeout}
          else
            {:cont, nil}
          end
      end
    end)
  end

  defp container_running?(container) do
    case System.cmd("docker", ["inspect", "--format", "{{.State.Running}}", container], stderr_to_stdout: true) do
      {"true\n", 0} -> true
      _ -> false
    end
  end

  defp pool_data_root(pool) do
    data_root = System.get_env("DRUZHOK_DATA_ROOT") || Path.expand("../../data", __DIR__)
    Path.join([data_root, "pools", pool.name])
  end


  defp get_docker_gid do
    case System.cmd("stat", ["-c", "%g", "/var/run/docker.sock"], stderr_to_stdout: true) do
      {gid, 0} -> String.trim(gid)
      _ -> nil
    end
  end
end
