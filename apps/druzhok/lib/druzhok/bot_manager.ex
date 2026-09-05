defmodule Druzhok.BotManager do
  @moduledoc """
  Top-level API for bot lifecycle. Generates env + config for the runtime,
  keeps DB state, and delegates process control to `Druzhok.Host`.
  """

  alias Druzhok.{Instance, InstanceManager, TokenPool, Repo}
  require Logger

  def create(name, opts) do
    with {:ok, opts} <- provision_ruoc(name, Map.new(opts)) do
      do_create(name, opts)
    end
  end

  # Once ruoc-gateway is configured every new bot gets its own account there
  # before anything is written locally, so a failed provision leaves no row.
  defp provision_ruoc(name, opts) do
    cond do
      opts[:ruoc_api_key] ->
        {:ok, opts}

      Druzhok.Ruoc.configured?() ->
        case Druzhok.Ruoc.create_account(ruoc_label(name, opts[:owner_telegram_id])) do
          {:ok, %{account_id: id, api_key: key}} ->
            {:ok,
             opts
             |> Map.merge(%{ruoc_account_id: id, ruoc_api_key: key})
             |> Map.update(:model, Druzhok.Ruoc.default_model(), &Druzhok.Ruoc.remap_model/1)}

          {:error, reason} ->
            Logger.error("ruoc account for #{name} failed: #{reason}")
            {:error, "ruoc-gateway account creation failed: #{reason}"}
        end

      true ->
        {:ok, opts}
    end
  end

  defp do_create(name, opts) do
    workspace = Path.join([data_root_base(), name, "workspace"])

    # A pooled token can only be claimed once the instance row exists
    # (tokens.instance_id is a foreign key), so pick first, claim after insert.
    token_result = if opts[:telegram_token] do
      {:ok, %{token: opts[:telegram_token], id: nil}}
    else
      TokenPool.peek_free()
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
            if token_record.id, do: TokenPool.claim(token_record, instance.id)
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
        runtime = Druzhok.Runtime.for_instance(instance)
        env = Druzhok.Runtime.base_env(instance) |> Map.merge(runtime.env_vars(instance))
        data_root = runtime.data_root(instance)

        write_workspace_files(data_root, runtime.workspace_files(instance))
        runtime.sync_config(instance, data_root)

        case Druzhok.Host.start(name, env, data_root) do
          :ok ->
            Logger.info("Started bot #{name}")
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
        suspend_ruoc(instance)
        Repo.delete(instance)
    end
    :ok
  end

  # What the ruoc console shows for the account: the bot name and, when
  # known, the owner's Telegram id so a top-up request can be matched.
  def ruoc_label(name, nil), do: "druzhok:" <> name
  def ruoc_label(name, owner_id), do: "druzhok:#{name} tg:#{owner_id}"

  # The ruoc account is suspended, never deleted, so its usage keeps its
  # explanation. A failure here is logged and does not block the delete.
  defp suspend_ruoc(%Instance{ruoc_account_id: id, name: name}) when is_binary(id) and id != "" do
    case Druzhok.Ruoc.suspend(id) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("could not suspend ruoc account #{id} for #{name}: #{reason}")
    end
  end

  defp suspend_ruoc(_), do: :ok

  @doc """
  Move a legacy bot onto ruoc-gateway: create its account, store the key,
  remap its models to ruoc ids and restart it so config.yaml is re-synced.
  Idempotent — a bot that already has a key is left alone.

  Funding is a separate operator action in the ruoc console.
  """
  def migrate_to_ruoc(name) do
    case Repo.get_by(Instance, name: name) do
      nil ->
        {:error, :not_found}

      %Instance{ruoc_api_key: key} when is_binary(key) and key != "" ->
        {:already_migrated, name}

      instance ->
        with {:ok, %{account_id: id, api_key: key}} <-
               Druzhok.Ruoc.create_account(ruoc_label(name, instance.owner_telegram_id)) do
          changes = %{
            ruoc_account_id: id,
            ruoc_api_key: key,
            model: Druzhok.Ruoc.remap_model(instance.model),
            image_model: Druzhok.Ruoc.remap_image_model(instance.image_model)
          }

          {:ok, updated} = instance |> Instance.changeset(changes) |> Repo.update()
          if updated.active, do: restart(name)
          Logger.info("Migrated #{name} to ruoc account #{id} (model #{updated.model})")
          {:ok, %{account_id: id, model: updated.model}}
        end
    end
  end

  defp wipe_data_dir(instance) do
    data_root = Druzhok.Runtime.for_instance(instance).data_root(instance)

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

  @doc "`%{mem_bytes, cpu_usec}` for a running bot, or nil."
  def stats(name), do: Druzhok.Host.stats(name)

  @doc "Run a command inside the bot's environment. Returns `{output, exit_code}`."
  def exec(name, args) when is_list(args), do: Druzhok.Host.exec(name, args)

  def logs(name, lines \\ 200), do: Druzhok.Host.logs(name, lines)

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
