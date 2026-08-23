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

  @impl true
  def start(name, env, _data_root) do
    with :ok <- check_name(name) do
      first_cmd = if status(name) == :unknown, do: "create", else: "update-env"

      with {_, 0} <- ctl([first_cmd, name], input: env_file(env)),
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
  def exec(name, args) do
    case check_name(name) do
      :ok -> ctl(["exec", name | args])
      {:error, _} -> {"invalid bot name", 1}
    end
  end

  @impl true
  def logs(name, lines) do
    with :ok <- check_name(name),
         {out, 0} <- ctl(["logs", name, to_string(lines)]) do
      String.trim_trailing(out)
    else
      _ -> ""
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
