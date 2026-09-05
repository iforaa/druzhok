defmodule Druzhok.Host.Process do
  @moduledoc """
  Dev/test `Druzhok.Host`: runs `hermes gateway run` as a child OS process
  (Erlang port) per bot. No isolation whatsoever — never use in production.
  """
  @behaviour Druzhok.Host

  use GenServer
  require Logger

  @ring 500

  # --- Druzhok.Host callbacks -------------------------------------------------

  @impl Druzhok.Host
  def start(name, env, data_root) do
    cond do
      not Druzhok.Host.valid_name?(name) ->
        {:error, :invalid_name}

      lookup(name) != nil ->
        :ok

      true ->
        spec = {__MODULE__, %{name: name, env: env, data_root: data_root}}

        case DynamicSupervisor.start_child(Druzhok.Host.ProcessSup, spec) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @impl Druzhok.Host
  def stop(name) do
    case lookup(name) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid, :normal, 10_000)
        catch
          :exit, _ -> :ok
        end
    end

    :ok
  end

  @impl Druzhok.Host
  def destroy(name), do: stop(name)

  @impl Druzhok.Host
  def status(name) do
    case lookup(name) do
      nil -> if Druzhok.Host.valid_name?(name), do: :inactive, else: :unknown
      pid -> safe_call(pid, :status, :inactive)
    end
  end

  @impl Druzhok.Host
  def stats(name) do
    with pid when pid != nil <- lookup(name),
         {:ok, os_pid} <- GenServer.call(pid, :os_pid),
         {out, 0} <- System.cmd("ps", ["-o", "rss=,time=", "-p", to_string(os_pid)]),
         [rss_kb, time] <- String.split(String.trim(out)) do
      %{mem_bytes: String.to_integer(rss_kb) * 1024, cpu_usec: parse_ps_time(time)}
    else
      _ -> nil
    end
  end

  @impl Druzhok.Host
  def exec(name, args) do
    case lookup(name) do
      nil ->
        {"no such bot", 1}

      pid ->
        %{env: env, cwd: cwd} = GenServer.call(pid, :config)
        [cmd | rest] = args

        try do
          System.cmd(resolve_bin(cmd), rest, env: Map.to_list(env), cd: cwd, stderr_to_stdout: true)
        rescue
          e in ErlangError -> {Exception.message(e), 127}
        end
    end
  end

  # No isolation in dev, so there is nothing to verify.
  @impl Druzhok.Host
  def egress_check(_name), do: :unenforced

  @impl Druzhok.Host
  def logs(name, lines) do
    case lookup(name) do
      nil -> ""
      pid -> pid |> GenServer.call(:logs) |> Enum.take(-lines) |> Enum.join("\n")
    end
  end

  # --- GenServer ---------------------------------------------------------------

  def child_spec(cfg) do
    %{id: {__MODULE__, cfg.name}, start: {__MODULE__, :start_link, [cfg]}, restart: :temporary}
  end

  def start_link(cfg), do: GenServer.start_link(__MODULE__, cfg, name: via(cfg.name))

  @impl GenServer
  def init(%{name: name, env: env, data_root: root}) do
    Process.flag(:trap_exit, true)
    # Same cwd as the prod unit's WorkingDirectory; env (incl. HERMES_HOME)
    # comes verbatim from Runtime.Hermes.env_vars/1.
    cwd = Path.join(root, "workspace")
    File.mkdir_p!(cwd)

    port_env =
      Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(to_string(v))} end)

    port =
      Port.open(
        {:spawn_executable, resolve_bin(Druzhok.Runtime.Hermes.bin())},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:line, 4096},
          {:args, ["gateway", "run"]},
          {:cd, cwd},
          {:env, port_env}
        ]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    Logger.info("Host.Process started #{name} (pid #{os_pid})")

    {:ok,
     %{
       name: name,
       env: env,
       cwd: cwd,
       port: port,
       os_pid: os_pid,
       status: :active,
       logs: []
     }}
  end

  @impl GenServer
  def handle_call(:status, _from, s), do: {:reply, s.status, s}
  def handle_call(:os_pid, _from, %{status: :active} = s), do: {:reply, {:ok, s.os_pid}, s}
  def handle_call(:os_pid, _from, s), do: {:reply, :error, s}
  def handle_call(:config, _from, s), do: {:reply, %{env: s.env, cwd: s.cwd}, s}
  def handle_call(:logs, _from, s), do: {:reply, Enum.reverse(s.logs), s}

  @impl GenServer
  def handle_info({port, {:data, {_eol, line}}}, %{port: port} = s) do
    {:noreply, %{s | logs: Enum.take([line | s.logs], @ring)}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = s) do
    Logger.warning("Host.Process #{s.name} exited with #{code}")
    {:noreply, %{s | status: if(code == 0, do: :inactive, else: :failed), port: nil}}
  end

  def handle_info(_, s), do: {:noreply, s}

  @impl GenServer
  def terminate(_reason, %{port: nil}), do: :ok

  def terminate(_reason, s) do
    # Port.close only closes the pipe; kill the OS process explicitly.
    System.cmd("kill", ["-TERM", to_string(s.os_pid)])

    try do
      Port.close(s.port)
    catch
      _, _ -> :ok
    end

    :ok
  end

  # --- helpers -----------------------------------------------------------------

  # Registry entries are removed asynchronously after a process exits, so a
  # lookup can briefly return a dead pid.
  defp safe_call(pid, msg, default) do
    GenServer.call(pid, msg)
  catch
    :exit, _ -> default
  end

  defp resolve_bin(bin), do: System.find_executable(bin) || bin

  defp via(name), do: {:via, Registry, {Druzhok.Registry, {name, :host_process}}}

  defp lookup(name) do
    case Registry.lookup(Druzhok.Registry, {name, :host_process}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # "MM:SS.ss" or "HH:MM:SS" → microseconds
  defp parse_ps_time(str) do
    parts =
      str
      |> String.split(":")
      |> Enum.map(fn p ->
        case Float.parse(p) do
          {f, _} -> f
          :error -> 0.0
        end
      end)

    secs =
      case parts do
        [h, m, s] -> h * 3600 + m * 60 + s
        [m, s] -> m * 60 + s
        [s] -> s
        _ -> 0.0
      end

    round(secs * 1_000_000)
  end
end
