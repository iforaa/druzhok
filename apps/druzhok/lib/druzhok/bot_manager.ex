defmodule Druzhok.BotManager do
  @moduledoc """
  Top-level API for bot lifecycle. `start/restart/stop/delete` record a
  request in the instance row; `Druzhok.Lifecycle` (one controller per bot in
  druzhok.service) carries it out, using `prepare_start/1` for the env and
  config files and `destroy_instance/1` for a delete.
  """

  import Ecto.Query, only: [from: 2]
  alias Druzhok.{Instance, InstanceManager, TokenPool, Repo}
  require Logger

  def create(name, opts) do
    with {:ok, opts} <- provision_ruoc(name, Map.new(opts)) do
      do_create(name, opts)
    end
  end

  # Once ruoc-gateway is configured every new bot gets its own account there
  # before anything is written locally, so a failed provision leaves no row.
  # Funding is ruoc's business: the account joins the operator's default plan
  # on creation and its first period is granted there.
  defp provision_ruoc(name, opts) do
    cond do
      opts[:ruoc_api_key] ->
        {:ok, opts}

      Druzhok.Ruoc.configured?() ->
        label = ruoc_label(name, opts[:owner_telegram_id])

        case Druzhok.Ruoc.create_account(label, invite: opts[:invite]) do
          {:ok, %{account_id: id, api_key: key}} ->
            {:ok,
             opts
             |> Map.merge(%{ruoc_account_id: id, ruoc_api_key: key})
             |> Map.update(:model, Druzhok.Ruoc.default_model(), &Druzhok.Ruoc.remap_model/1)}

          {:error, {:invite, _} = refused} ->
            # The gate held: no account, no row, and the person is told the
            # code did not work. Not logged as an error — it is theirs to fix.
            {:error, refused}

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
            admit_owner(opts)
            # The row is created stopped; the caller asks for the start once
            # it has written what the first start should see (SOUL.md), so a
            # slow or failed first start is never a creation error.
            {:ok, %{name: name, model: instance.model}}

          error -> error
        end

      {:error, :no_tokens_available} ->
        {:error, "No Telegram tokens available in pool"}
    end
  end

  @doc """
  Ask for a fresh start with what is in the row now (also wakes an asleep
  bot). Start and restart are the same request: `active = true` and
  `start_seq + 1`. The lifecycle controller in druzhok.service carries it out
  (`Druzhok.Lifecycle`). With `wait: true`, returns once it is done:
  `{:ok, name}`, `{:error, reason}` for a failed start of this request, or
  `{:error, :timeout}`.
  """
  def start(name, opts \\ []) do
    case bump(name, [set: [active: true], inc: [start_seq: 1]], :start_seq) do
      nil -> {:error, :not_found}
      {id, seq} -> if opts[:wait], do: wait_started(id, name, seq, opts), else: {:ok, name}
    end
  end

  def restart(name, opts \\ []), do: start(name, opts)

  @doc """
  Ask for the bot to stop and stay stopped (`active = false`). The relay
  holds its updates at once; the controller pauses, drains and stops the unit.
  With `wait: true`, returns `:ok` once the controller has acknowledged it.
  """
  def stop(name, opts \\ []) do
    case bump(name, [set: [active: false], inc: [stop_seq: 1]], :stop_seq) do
      nil -> :ok
      {id, seq} -> if opts[:wait], do: wait_stopped(id, seq, opts), else: :ok
    end
  end

  # One update, then a poke. Returns {id, value of `field` after it}.
  defp bump(name, changes, field) do
    query = from(i in Instance, where: i.name == ^name, select: {i.id, field(i, ^field)})

    case Repo.update_all(query, changes) do
      {1, [{id, seq}]} ->
        Druzhok.Lifecycle.poke(id)
        {id, seq}

      _ ->
        nil
    end
  end

  defp wait_started(id, name, seq, opts) do
    wait_for(id, opts, fn
      nil -> {:error, :not_found}
      %Instance{applied_seq: a} when a >= seq -> {:ok, name}
      %Instance{failed_seq: f, start_error: err} when f >= seq -> {:error, err}
      _ -> nil
    end)
  end

  defp wait_stopped(id, seq, opts) do
    wait_for(id, opts, fn
      nil -> :ok
      %Instance{stopped_seq: s} when s >= seq -> :ok
      _ -> nil
    end)
  end

  defp wait_for(id, opts, done) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout, wait_timeout())
    poll(id, deadline, done)
  end

  defp poll(id, deadline, done) do
    case done.(Repo.get(Instance, id)) do
      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(wait_poll_ms())
          poll(id, deadline, done)
        end

      result ->
        result
    end
  end

  defp wait_timeout, do: Application.get_env(:druzhok, :lifecycle_wait_ms, 120_000)
  defp wait_poll_ms, do: Application.get_env(:druzhok, :lifecycle_wait_poll_ms, 250)

  @doc false
  # The start action's file work, run by the controller before Host.start:
  # workspace seed files and config.yaml. Returns `{env, data_root}`.
  def prepare_start(%Instance{} = instance) do
    runtime = Druzhok.Runtime.for_instance(instance)
    env = Druzhok.Runtime.base_env(instance) |> Map.merge(runtime.env_vars(instance))
    data_root = runtime.data_root(instance)

    write_workspace_files(data_root, runtime.workspace_files(instance))
    # The operator is the hermes slash-command admin on every bot
    # (Runtime.Hermes.sync_config/2); the instance row does not carry it.
    runtime.sync_config(
      Map.put(instance, :operator_telegram_id, Druzhok.Settings.operator_telegram_id()),
      data_root
    )

    {env, data_root}
  end

  @doc """
  Turn the image tool on or off and name the ruoc image model (nil = ruoc's
  default). A row update only: the caller restarts when `enabled?` changed,
  since only the on/off state reaches hermes's config.
  """
  def update_image_gen(name, enabled?, model) when is_boolean(enabled?) do
    case Repo.get_by(Instance, name: name) do
      nil -> {:error, :not_found}
      inst -> inst |> Instance.changeset(%{image_gen_enabled: enabled?, image_gen_model: model}) |> Repo.update()
    end
  end

  @doc """
  Ask for the bot to be deleted: stop and remove its unit and user, wipe its
  on-disk data dir (config, SOUL, memory, history, logs), release its
  Telegram token to the pool, suspend its ruoc account and drop the row.
  Irreversible. The controller does it (`destroy_instance/1`); with
  `wait: true`, returns `:ok` once the row is gone.
  """
  def delete(name, opts \\ []) do
    query = from(i in Instance, where: i.name == ^name, select: i.id)

    case Repo.update_all(query, set: [active: false, delete_requested: true]) do
      {1, [id]} ->
        Druzhok.Lifecycle.poke(id)
        if opts[:wait], do: wait_for(id, opts, fn nil -> :ok; _ -> nil end), else: :ok

      _ ->
        :ok
    end
  end

  @doc false
  # Rule 3 of the controller, once the unit is stopped. Every step is
  # idempotent, so a controller that died part way simply runs it again.
  def destroy_instance(%Instance{} = instance) do
    Druzhok.Host.destroy(instance.name)
    wipe_data_dir(instance)
    TokenPool.release(instance.id)
    suspend_ruoc(instance)
    Repo.delete(instance, stale_error_field: :id)
    :ok
  end

  # What the ruoc console shows for the account: the bot name and, when
  # known, the owner's Telegram id so a top-up request can be matched.
  def ruoc_label(name, nil), do: "druzhok:" <> name
  def ruoc_label(name, owner_id), do: "druzhok:#{name} tg:#{owner_id}"

  # Creating a bot is what admission means. With a code the hint is its first
  # characters; without one (the operator, a grandfathered owner, a recreate)
  # the row says "owner" so the console can tell the two apart.
  defp admit_owner(%{owner_telegram_id: owner} = opts) when is_integer(owner) do
    hint = if code = opts[:invite], do: String.slice(code, 0, 4), else: "owner"
    Druzhok.Admissions.admit(owner, hint)
  end

  defp admit_owner(_), do: :ok

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

  @doc "Unit/process state as a string: active | activating | restarting | stopping | inactive | failed | unknown"
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
