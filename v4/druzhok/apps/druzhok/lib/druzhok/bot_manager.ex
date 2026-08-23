defmodule Druzhok.BotManager do
  @moduledoc """
  Top-level API for bot container lifecycle.
  Creates, starts, stops, restarts Docker containers running bot runtimes.
  """

  alias Druzhok.{Instance, InstanceManager, TokenPool, Repo}
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
      nil ->
        {:error, :not_found}

      instance ->
        runtime = Druzhok.Runtime.get(instance.bot_runtime || "hermes", Druzhok.Runtime.Hermes)
        env = Druzhok.Runtime.base_env(instance) |> Map.merge(runtime.env_vars(instance))
        image = runtime.docker_image()
        command = runtime.gateway_command()
        data_root = Path.dirname(instance.workspace)

        write_workspace_files(data_root, runtime.workspace_files(instance))
        sync_runtime_config(runtime, instance, data_root)

        case start_container(name, image, env, data_root, runtime.data_mount_path(), command) do
          {:ok, container_id} ->
            Logger.info("Started bot container #{name}: #{container_id}")

            Task.start(fn ->
              case runtime.post_start(instance) do
                :ok ->
                  :ok

                {:error, reason} ->
                  Logger.error("Post-start config for #{name} failed: #{inspect(reason)}")
              end

              case Druzhok.LogWatcher.start_link(
                     name: name,
                     runtime: runtime,
                     bot_token: instance.telegram_token,
                     language: instance.language || "ru",
                     reject_message: instance.reject_message
                   ) do
                {:ok, pid} ->
                  Logger.info("LogWatcher started for #{name}: #{inspect(pid)}")

                {:error, reason} ->
                  Logger.error("LogWatcher failed for #{name}: #{inspect(reason)}")
              end
            end)

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
    Druzhok.LogWatcher.stop(name)

    case Repo.get_by(Instance, name: name) do
      nil ->
        :ok

      instance ->
        stop_container(name)
        Druzhok.HealthMonitor.unregister(name)
        instance |> Ecto.Changeset.change(%{active: false}) |> Repo.update!()
    end

    :ok
  end

  def restart(name) do
    # Serialize per-bot: rapid UI clicks race on `docker run --name`. Losers
    # no-op; the winner's start/1 re-reads DB state so no change is lost.
    case :global.set_lock({{:bot_restart, name}, self()}, [node()], 0) do
      true ->
        try do
          stop(name)
          Process.sleep(1_000)
          start(name)
        after
          :global.del_lock({{:bot_restart, name}, self()}, [node()])
        end

      false ->
        Logger.info("restart(#{name}): another restart already in progress, skipping")
        :ok
    end
  end

  @doc """
  Fully delete a bot: stop+remove its container, wipe its on-disk data dir
  (config, SOUL, memory, history, logs), release its Telegram token back to
  the pool, and delete the DB row. Irreversible.
  """
  def delete(name) do
    stop(name)
    case Repo.get_by(Instance, name: name) do
      nil -> :ok
      instance ->
        wipe_data_dir(instance)
        TokenPool.release(instance.id)
        Repo.delete(instance)
    end
    :ok
  end

  defp wipe_data_dir(instance) do
    data_root = case instance.workspace do
      ws when is_binary(ws) and ws != "" -> Path.dirname(ws)
      _ -> nil
    end

    if safe_to_wipe?(data_root) do
      case File.rm_rf(data_root) do
        {:ok, _} -> Logger.info("Wiped data dir for #{instance.name}: #{data_root}")
        {:error, reason, file} ->
          Logger.error("Failed to wipe #{data_root} (#{file}): #{inspect(reason)}")
      end
    else
      Logger.warning("Refusing to wipe unsafe data dir for #{instance.name}: #{inspect(data_root)}")
    end
  end

  # Only ever remove a path that sits strictly *under* the configured data
  # root — never the root itself, "/", a blank, or anything outside it. Guards
  # against a malformed instance.workspace nuking something unexpected.
  def safe_to_wipe?(nil), do: false
  def safe_to_wipe?(""), do: false
  def safe_to_wipe?(path) when is_binary(path) do
    root = data_root_base()
    abs = Path.expand(path)
    abs not in ["/", root] and String.starts_with?(abs <> "/", root <> "/")
  end
  def safe_to_wipe?(_), do: false

  @doc """
  Canonical host path under which every bot's data dir lives
  (`<data_root_base>/<bot>/workspace/...`). Public so the web layer can resolve
  the same root when serving published sites.
  """
  def data_root_base do
    (System.get_env("DRUZHOK_DATA_ROOT") || Path.expand("../../../data/tenants", __DIR__))
    |> Path.expand()
  end

  def status(name), do: status_for_container(container_name(name))

  def stats(name), do: stats_for_container(container_name(name))

  def status_for_container(container) do
    {output, exit_code} = System.cmd("docker", ["inspect", "--format", "{{.State.Status}}", container], stderr_to_stdout: true)
    if exit_code == 0, do: String.trim(output), else: "not_found"
  end

  def stats_for_container(container) do
    {output, exit_code} = System.cmd("docker", [
      "stats", "--no-stream", "--format",
      "{{.MemUsage}}|{{.CPUPerc}}|{{.NetIO}}",
      container
    ], stderr_to_stdout: true)

    if exit_code == 0 do
      case String.trim(output) |> String.split("|") do
        [mem, cpu, net] ->
          # docker .MemUsage is "31.02MiB / 1.921GiB" — the denominator is host
          # RAM (no --memory cap set), useful only as a reference.
          mem_used = mem |> String.split("/") |> List.first() |> String.trim()
          %{mem: mem_used, mem_bytes: parse_mem_bytes(mem_used), cpu: cpu, net: net}

        _ ->
          nil
      end
    else
      nil
    end
  end

  @mem_regex ~r/^\s*([\d.]+)\s*(KiB|MiB|GiB|TiB|B)?/
  @unit_factors %{"B" => 1, "KiB" => 1024, "MiB" => 1024 * 1024,
                  "GiB" => 1024 * 1024 * 1024, "TiB" => 1024 * 1024 * 1024 * 1024}

  defp parse_mem_bytes(mem_string) when is_binary(mem_string) do
    with [_, n, unit] <- Regex.run(@mem_regex, mem_string),
         {value, _} <- Float.parse(n) do
      round(value * Map.get(@unit_factors, unit, 1))
    else
      _ -> 0
    end
  end

  defp parse_mem_bytes(_), do: 0

  defp sync_runtime_config(runtime, instance, data_root) do
    if function_exported?(runtime, :sync_config, 2) do
      runtime.sync_config(instance, data_root)
    else
      :ok
    end
  end

  defp write_workspace_files(data_root, files) do
    for entry <- files do
      {rel_path, content, mode} =
        case entry do
          {p, c} -> {p, c, :always}
          {p, c, m} -> {p, c, m}
        end

      full_path = Path.join(data_root, rel_path)
      File.mkdir_p!(Path.dirname(full_path))

      cond do
        mode == :create_only and File.exists?(full_path) ->
          :ok

        true ->
          File.write!(full_path, content)
      end
    end

    :ok
  end

  defp start_container(name, image, env, data_root, mount_path, command) do
    env_args = Enum.flat_map(env, fn {k, v} -> ["-e", "#{k}=#{v}"] end)

    # If the adapter sets HERMES_UID, it handles privilege dropping itself
    # via gosu in the entrypoint — don't pass --user or it bypasses gosu.
    # Other runtimes (zeroclaw, picoclaw, etc.) need --user explicitly.
    user_flag =
      if Map.has_key?(env, "HERMES_UID") do
        []
      else
        case host_user_gid() do
          nil -> []
          ids -> ["--user", ids]
        end
      end

    args =
      [
        "run",
        "-d",
        "--name",
        container_name(name),
        "--network",
        "host",
        "--restart",
        "unless-stopped",
        "--shm-size",
        "2g",
        "-v",
        "#{data_root}:#{mount_path}"
      ] ++ user_flag ++ env_args ++ [image | List.wrap(command)]

    case System.cmd("docker", args, stderr_to_stdout: true) do
      {container_id, 0} -> {:ok, String.trim(container_id)}
      {error, _} -> {:error, String.trim(error)}
    end
  end

  defp stop_container(name) do
    container = container_name(name)
    # Clear the restart policy first so docker doesn't race to resurrect
    # a container that's crashing in a restart loop. See CLAUDE.md.
    System.cmd("docker", ["update", "--restart=no", container], stderr_to_stdout: true)
    System.cmd("docker", ["rm", "-f", container], stderr_to_stdout: true)
    :ok
  end

  @doc "Host user UID, cached for the BEAM lifetime. Returns nil on failure."
  def host_uid, do: cached_id(:host_uid, "-u")

  @doc "Host user GID, cached for the BEAM lifetime. Returns nil on failure."
  def host_gid, do: cached_id(:host_gid, "-g")

  defp cached_id(key, flag) do
    case :persistent_term.get({__MODULE__, key}, :unset) do
      :unset ->
        value =
          case System.cmd("id", [flag], stderr_to_stdout: true) do
            {out, 0} -> String.trim(out)
            _ -> nil
          end

        :persistent_term.put({__MODULE__, key}, value)
        value

      cached ->
        cached
    end
  end

  defp host_user_gid do
    case {host_uid(), host_gid()} do
      {uid, gid} when is_binary(uid) and is_binary(gid) -> "#{uid}:#{gid}"
      _ -> nil
    end
  end

  def container_name(name), do: "druzhok-bot-#{name}"

  @doc """
  Run a command inside a bot container. Returns `{output, exit_code}`.

  Used by runtime-specific flows that need to invoke a tool inside the
  container (e.g. hermes's pairing-code approve).

  ## Options

    * `:user` — run as a specific user inside the container (string passed
      to `docker exec -u`). Defaults to the container default, which is
      **root** for most images — this is usually wrong for hermes, whose
      gateway runs as uid 1000, so callers should pass e.g. `user: "hermes"`
      when exec'ing tools that touch files the server will later read.
  """
  def exec(name, args, opts \\ []) when is_list(args) do
    user_flag = case Keyword.get(opts, :user) do
      nil -> []
      user -> ["-u", to_string(user)]
    end

    System.cmd("docker", ["exec"] ++ user_flag ++ [container_name(name) | args], stderr_to_stdout: true)
  end
end
