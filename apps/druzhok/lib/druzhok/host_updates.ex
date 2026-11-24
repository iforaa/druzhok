defmodule Druzhok.HostUpdates do
  @moduledoc """
  Every hour: checks that the host keeps its kernel and packages patched, and
  tells the operator (`DiskCheck.tell_operator/1`) when it does not. Each
  problem is reported at most once a day while it lasts.

  The host side is plain Ubuntu: unattended-upgrades installs security updates
  daily and `/etc/apt/apt.conf.d/52druzhok-auto-reboot` reboots at 23:00 UTC
  when one needs it, so a kernel fix is live within about a day (no Livepatch:
  it needs Ubuntu Pro). This module only watches that it all still happens:

    * `:upgrades_stale` — unattended-upgrades has not run for 2 days
      (`/var/lib/apt/periodic/upgrade-stamp`).
    * `:reboot_overdue` — a reboot has been pending for 3 days
      (`/var/run/reboot-required`), so the nightly reboot is not happening.

  Both are readable by the `druzhok` user. On a machine with no
  `/var/lib/apt/periodic` (dev, tests) it does nothing. Runs only where
  druzhok.service serves (`DruzhokWeb.Application`), so there is one sender.
  """

  use GenServer
  require Logger
  alias Druzhok.DiskCheck

  @every_ms 60 * 60 * 1000
  @first_ms 5 * 60 * 1000
  @report_every_s 24 * 3600
  @upgrades_max_age_s 2 * 24 * 3600
  @reboot_max_age_s 3 * 24 * 3600

  @defaults %{
    periodic_dir: "/var/lib/apt/periodic",
    reboot_required: "/var/run/reboot-required"
  }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    paths = Map.merge(@defaults, Map.new(Keyword.get(opts, :paths, [])))
    Process.send_after(self(), :check, Keyword.get(opts, :first_ms, @first_ms))
    {:ok, %{paths: paths, reported: %{}, every_ms: Keyword.get(opts, :every_ms, @every_ms)}}
  end

  @impl true
  def handle_info(:check, state) do
    state =
      try do
        run(state, System.os_time(:second))
      rescue
        e ->
          Logger.error("[host-updates] check failed: #{Exception.message(e)}")
          state
      end

    Process.send_after(self(), :check, state.every_ms)
    {:noreply, state}
  end

  @doc false
  def run(state, now) do
    if File.dir?(state.paths.periodic_dir) do
      problems = problems(facts(state.paths), now)
      Enum.reduce(problems, state, fn {kind, text}, acc -> report(acc, kind, now, text) end)
    else
      state
    end
  end

  @doc """
  The problems in `facts`, as `[{kind, text}]`. `facts` holds unix times
  (`:upgrade_stamp`, `:reboot_required`), nil when the file is absent.
  """
  def problems(facts, now) do
    [
      case facts.upgrade_stamp do
        nil ->
          {:upgrades_stale, "Автообновления сервера не запускались: нет upgrade-stamp."}

        t when now - t > @upgrades_max_age_s ->
          {:upgrades_stale,
           "Автообновления сервера не запускались #{days(now - t)} дн. " <>
             "Проверь: systemctl status unattended-upgrades apt-daily-upgrade.timer"}

        _ ->
          nil
      end,
      case facts.reboot_required do
        t when is_integer(t) and now - t > @reboot_max_age_s ->
          {:reboot_overdue,
           "Сервер ждёт перезагрузки #{days(now - t)} дн., ночная перезагрузка не сработала. " <>
             "См. /var/run/reboot-required.pkgs и /etc/apt/apt.conf.d/52druzhok-auto-reboot"}

        _ ->
          nil
      end
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp facts(paths) do
    %{
      upgrade_stamp: mtime(Path.join(paths.periodic_dir, "upgrade-stamp")),
      reboot_required: mtime(paths.reboot_required)
    }
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: t}} -> t
      _ -> nil
    end
  end

  defp report(state, kind, now, text) do
    case state.reported[kind] do
      last when is_integer(last) and now - last < @report_every_s ->
        state

      _ ->
        Logger.warning("[host-updates] #{text}")
        DiskCheck.tell_operator(text)
        %{state | reported: Map.put(state.reported, kind, now)}
    end
  end

  defp days(seconds), do: div(seconds, 24 * 3600)
end
