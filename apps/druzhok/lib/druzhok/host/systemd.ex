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

  @impl true
  def start(name, env, _data_root) do
    # `create` is idempotent: ensures user + dirs + nft membership and
    # (re)writes the env file, so it doubles as update-env on restarts.
    with :ok <- check_name(name) do
      with {_, 0} <- ctl(["create", name], input: env_file(env)),
           {_, 0} <- ctl(["start", name]) do
        :ok
      else
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
    with :ok <- check_name(name), do: ctl(["destroy", name])
    :ok
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

  @impl true
  def exec(name, args) do
    case check_name(name) do
      :ok -> ctl(["exec", name | args])
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
        # System.cmd has no stdin; hand the env file over via a 0600 temp file.
        tmp = Path.join(System.tmp_dir!(), "druzhok-env-#{System.unique_integer([:positive])}")
        File.write!(tmp, input)
        File.chmod!(tmp, 0o600)

        try do
          System.cmd("sh", ["-c", ~s(exec "$0" "$@" < "#{tmp}"), bin | prefix ++ args],
            stderr_to_stdout: true
          )
        after
          File.rm(tmp)
        end
    end
  end
end
