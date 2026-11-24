defmodule Druzhok.Host.Systemd do
  @moduledoc """
  Production `Druzhok.Host`: every bot is a Linux user `bot-<name>` running the
  template unit `hermes@<name>.service`. All privileged operations go through
  the root helper `druzhok-ctl` (see `ops/druzhok-ctl`), invoked via sudo.
  Secrets are passed on stdin as an `EnvironmentFile`, never on argv.
  """
  @behaviour Druzhok.Host
  require Logger

  @default_ctl ["sudo", "-n", "/usr/local/sbin/druzhok-ctl"]
  @cgroup_dir "/sys/fs/cgroup/system.slice/system-hermes.slice"

  # `create` is idempotent: ensures user + dirs + nft membership and
  # (re)writes the env file, so it doubles as update-env on restarts. Then the
  # bot's disk limit, so every start and wake applies the current one.
  @impl true
  def prepare(name, env, _data_root) do
    with :ok <- check_name(name),
         :ok <- check_env(env) do
      case ctl(["create", name], input: env_file(env)) do
        {_, 0} ->
          apply_disk_limit(name)
          :ok

        {out, code} ->
          {:error, {:druzhok_ctl, code, String.trim(out)}}
      end
    end
  end

  # Never fails the start: an unlimited bot is better than a bot that is down,
  # and Druzhok.DiskCheck reports a bot with no limit.
  defp apply_disk_limit(name) do
    result =
      case Druzhok.DiskLimit.limit_by_name(name) do
        :off -> quota(name, :off, 0)
        {mb, files} -> quota(name, mb, files)
      end

    # `create` just made the user, so :no_user cannot happen here.
    with {:error, _} <- result,
         do: Logger.error("[host] #{name}: disk limit not set: #{inspect(result)}")
  rescue
    e -> Logger.error("[host] #{name}: disk limit not set: #{Exception.message(e)}")
  end

  # Not through `create`: that rewrites the env file from stdin.
  @impl true
  def quota(name, disk_mb, files) do
    args =
      case disk_mb do
        :off -> ["off"]
        mb -> [Integer.to_string(mb), Integer.to_string(files)]
      end

    with :ok <- check_name(name) do
      case ctl(["quota", name | args]) do
        {_, 0} -> :ok
        # No `bot-<name>` user yet: the bot never started, and its first start sets the limit.
        {_, 3} -> :no_user
        {out, code} -> {:error, {:druzhok_ctl, code, String.trim(out)}}
      end
    end
  end

  @impl true
  def disk_all do
    case ctl(["disk-all"]) do
      {out, 0} -> parse_disk_all(out)
      {out, code} -> {:error, {:druzhok_ctl, code, String.trim(out)}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def quotas do
    case ctl(["quotas"]) do
      {out, 0} ->
        case String.trim(out) do
          "on" -> :on
          "off" -> :off
          other -> {:error, {:druzhok_ctl, 0, other}}
        end

      {out, code} ->
        {:error, {:druzhok_ctl, code, String.trim(out)}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc false
  # `-` alone is quotas off; else `name|used_kb|limit_kb|files|file_limit`
  # lines. A line that does not read is skipped, not fatal for the rest.
  def parse_disk_all(out) do
    case String.trim(out) do
      "-" ->
        :off

      text ->
        disks =
          for line <- String.split(text, "\n", trim: true),
              [name | numbers] <- [String.split(String.trim(line), "|")],
              Druzhok.Host.valid_name?(name),
              [used, limit, files, file_limit] <- [parse_numbers(numbers)],
              into: %{},
              do: {name, %{used_kb: used, limit_kb: limit, files: files, file_limit: file_limit}}

        {:ok, disks}
    end
  end

  defp parse_numbers(fields) do
    parsed = Enum.map(fields, &Integer.parse/1)
    if Enum.all?(parsed, &match?({n, ""} when n >= 0, &1)), do: Enum.map(parsed, &elem(&1, 0))
  end

  # The tenant dir is in /data/tenants, which is root's: only the helper can
  # remove it, and it refuses while the bot's user is still there.
  @impl true
  def wipe(name, _data_root) do
    with :ok <- check_name(name) do
      case ctl(["purge", name]) do
        {_, 0} -> :ok
        {out, code} -> {:error, {:druzhok_ctl, code, String.trim(out)}}
      end
    end
  end

  @impl true
  def start(name, _env, _data_root) do
    with :ok <- check_name(name) do
      case ctl(["start", name]) do
        {_, 0} -> :ok
        {out, code} -> {:error, {:druzhok_ctl, code, String.trim(out)}}
      end
    end
  end

  @impl true
  def stop(name) do
    with :ok <- check_name(name), do: ctl(["stop", name])
    :ok
  end

  @impl true
  def destroy(name) do
    with :ok <- check_name(name) do
      case ctl(["destroy", name]) do
        {_, 0} -> :ok
        {out, code} -> {:error, {:druzhok_ctl, code, String.trim(out)}}
      end
    end
  end

  @impl true
  def status(name) do
    with :ok <- check_name(name),
         {out, 0} <- ctl(["status", name]) do
      case String.trim(out) do
        "active" -> :active
        "activating" -> :activating
        "restarting" -> :restarting
        "stopping" -> :stopping
        "inactive" -> :inactive
        "failed" -> :failed
        "created" -> :inactive
        _ -> :unknown
      end
    else
      _ -> :unknown
    end
  end

  @impl true
  def stats(name) do
    with :ok <- check_name(name),
         {out, 0} <- ctl(["stats", name]),
         [mem, cpu] <- out |> String.trim() |> String.split("|"),
         {m, ""} <- Integer.parse(mem),
         {c, ""} <- Integer.parse(cpu) do
      %{mem_bytes: m, cpu_usec: c}
    else
      _ -> nil
    end
  end

  @impl true
  def procs(name) do
    with :ok <- check_name(name),
         {out, 0} <- ctl(["procs", name]),
         {n, ""} <- Integer.parse(String.trim(out)) do
      n
    else
      _ -> nil
    end
  end

  # The cgroup is world-readable, and it exists only while the unit does: a
  # sleeping or stopped bot, or a row with no unit, has none.
  @impl true
  def memory_bytes(name), do: read_cgroup(name, "memory.current")

  # "max" is no ceiling at all.
  @impl true
  def memory_max_bytes(name), do: read_cgroup(name, "memory.max")

  defp read_cgroup(name, file) do
    dir = Application.get_env(:druzhok, :hermes_cgroup_dir, @cgroup_dir)

    with :ok <- check_name(name),
         {:ok, text} <- File.read(Path.join([dir, "hermes@#{name}.service", file])),
         {bytes, ""} <- Integer.parse(String.trim(text)) do
      bytes
    else
      {:error, reason} when reason in [:enoent, :invalid_name] ->
        nil

      :error when file == "memory.max" ->
        nil

      other ->
        Logger.warning("[host] #{name}: cannot read #{file}: #{inspect(other)}")
        nil
    end
  end

  # `input:` becomes the command's stdin (`druzhok-ctl exec` passes it on).
  @impl true
  def exec(name, args, opts \\ []) do
    case check_name(name) do
      :ok -> ctl(["exec", name | args], opts)
      {:error, _} -> {"invalid bot name", 1}
    end
  end

  # One `systemctl list-units` for all bots, without sudo: unit states are
  # world-readable. Every listed state but inactive and failed holds memory.
  @impl true
  def holding_units do
    bin = Application.get_env(:druzhok, :systemctl_bin, "systemctl")

    args =
      ~w(list-units --all --plain --no-legend --no-pager --type=service) ++ ["hermes@*.service"]

    case System.cmd(bin, args, env: [{"LC_ALL", "C"}], stderr_to_stdout: true) do
      {out, 0} -> {:ok, parse_units(out)}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @holding %{
    "active" => :active,
    "activating" => :activating,
    "reloading" => :reloading,
    "deactivating" => :deactivating
  }

  @doc false
  # UNIT LOAD ACTIVE SUB DESCRIPTION; an older systemd marks a failed unit
  # with a leading bullet even with --plain.
  def parse_units(out) do
    for line <- String.split(out, "\n", trim: true),
        [unit, _load, active | _] <- [line |> String.split() |> Enum.drop_while(&(&1 == "●"))],
        name = unit_name(unit),
        name != nil,
        state = @holding[active],
        state != nil,
        into: %{},
        do: {name, state}
  end

  defp unit_name("hermes@" <> rest) do
    name = String.replace_suffix(rest, ".service", "")
    if Druzhok.Host.valid_name?(name), do: name
  end

  defp unit_name(_), do: nil

  @doc """
  `:ok`, or `{:error, {:bad_env, key}}` for a value with a line break or a NUL.
  `env_file/1` escapes quotes and backslashes only, so a line break in a value
  (a token or a name someone typed) would start a line of its own in the file
  druzhok-ctl writes: another variable, read by the bot and by druzhok-ctl.
  """
  def check_env(env) do
    case Enum.find(env, fn {_k, v} -> String.contains?(to_string(v), ["\n", "\r", <<0>>]) end) do
      nil -> :ok
      {k, _} -> {:error, {:bad_env, k}}
    end
  end

  @doc "Serialise env as a systemd EnvironmentFile (sorted, double-quoted, escaped)."
  def env_file(env) do
    env
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {k, v} ->
      escaped =
        v
        |> to_string()
        |> String.replace("\\", "\\\\")
        |> String.replace("\"", "\\\"")

      ~s(#{k}="#{escaped}"\n)
    end)
    |> Enum.join()
  end

  # --- helpers ---------------------------------------------------------------

  defp check_name(name),
    do: if(Druzhok.Host.valid_name?(name), do: :ok, else: {:error, :invalid_name})

  defp ctl(args, opts \\ []) do
    [bin | prefix] = Application.get_env(:druzhok, :druzhok_ctl, @default_ctl)

    case Keyword.get(opts, :input) do
      nil ->
        System.cmd(bin, prefix ++ args, stderr_to_stdout: true)

      input ->
        Druzhok.Cmd.run(bin, prefix ++ args, input, stderr_to_stdout: true)
    end
  end
end
