defmodule Druzhok.BotManager do
  @moduledoc """
  Top-level API for bot lifecycle. Generates env + config for the runtime,
  keeps DB state, and delegates process control to `Druzhok.Host`.
  """

  alias Druzhok.{Instance, InstanceManager, TokenPool, Repo}
  require Logger

  def create(name, opts) do
    workspace = Path.join([data_root_base(), name, "workspace"])

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
          tenant_key: tenant_key
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
        data_root = runtime.data_root(instance)

        File.mkdir_p!(Path.join(data_root, "home"))
        write_workspace_files(data_root, runtime.workspace_files(instance))
        sync_runtime_config(runtime, instance, data_root)

        case Druzhok.Host.start(name, env, data_root) do
          :ok ->
            Logger.info("Started bot #{name}")

            Task.start(fn ->
              case runtime.post_start(instance) do
                :ok -> :ok
                {:error, reason} -> Logger.error("Post-start for #{name} failed: #{inspect(reason)}")
              end
            end)

            Druzhok.HealthMonitor.register(name)
            Repo.update(Instance.changeset(instance, %{active: true}))
            {:ok, name}

          {:error, reason} ->
            Logger.error("Failed to start bot #{name}: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  def stop(name) do
    case Repo.get_by(Instance, name: name) do
      nil ->
        :ok

      instance ->
        Druzhok.Host.stop(name)
        Druzhok.HealthMonitor.unregister(name)
        instance |> Ecto.Changeset.change(%{active: false}) |> Repo.update!()
    end

    :ok
  end

  def restart(name) do
    # Serialize per-bot: rapid UI clicks race on unit start. Losers
    # no-op; the winner's start/1 re-reads DB state so no change is lost.
    case :global.set_lock({{:bot_restart, name}, self()}, [node()], 0) do
      true ->
        try do
          stop(name)
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
  Fully delete a bot: stop+remove its unit and user, wipe its on-disk data dir
  (config, SOUL, memory, history, logs), release its Telegram token back to
  the pool, and delete the DB row. Irreversible.
  """
  def delete(name) do
    stop(name)
    case Repo.get_by(Instance, name: name) do
      nil -> :ok
      instance ->
        Druzhok.Host.destroy(name)
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
    (System.get_env("DRUZHOK_DATA_ROOT") || Application.get_env(:druzhok, :data_root_default))
    |> Path.expand()
  end

  @doc "Unit/process state as a string: active | activating | inactive | failed | unknown"
  def status(name), do: name |> Druzhok.Host.status() |> Atom.to_string()

  @doc "Resource usage in the shape the dashboard renders, or nil."
  def stats(name) do
    case Druzhok.Host.stats(name) do
      %{mem_bytes: mem, cpu_usec: cpu} ->
        %{mem: human_bytes(mem), mem_bytes: mem, cpu: "#{Float.round(cpu / 1_000_000, 1)}s", net: ""}

      nil ->
        nil
    end
  end

  @doc "Run a command inside the bot's environment. Returns `{output, exit_code}`."
  def exec(name, args) when is_list(args), do: Druzhok.Host.exec(name, args)

  def logs(name, lines \\ 200), do: Druzhok.Host.logs(name, lines)

  defp human_bytes(b) when b >= 1024 * 1024 * 1024, do: "#{Float.round(b / (1024 * 1024 * 1024), 2)}GiB"
  defp human_bytes(b) when b >= 1024 * 1024, do: "#{Float.round(b / (1024 * 1024), 1)}MiB"
  defp human_bytes(b) when b >= 1024, do: "#{div(b, 1024)}KiB"
  defp human_bytes(b), do: "#{b}B"

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
end
