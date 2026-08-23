defmodule Druzhok.HealthMonitor do
  @moduledoc """
  Runs `Druzhok.HealthMonitor.Probe` for every registered bot every 60 s.
  Three consecutive `:down` results restart the bot. Every transition into
  degraded/down is recorded in `crash_logs` so /errors is the alert feed.
  """
  use GenServer
  require Logger

  @interval 60_000
  @max_failures 3
  @probe_timeout 20_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def register(name), do: GenServer.cast(__MODULE__, {:register, name})
  def unregister(name), do: GenServer.cast(__MODULE__, {:unregister, name})
  def list, do: GenServer.call(__MODULE__, :list)

  @impl true
  def init(_) do
    schedule()
    {:ok, %{bots: %{}}}
  end

  @impl true
  def handle_cast({:register, name}, s) do
    entry = %{status: :healthy, reasons: [], failures: 0, checked_at: nil}
    {:noreply, put_in(s, [:bots, name], entry)}
  end

  def handle_cast({:unregister, name}, s), do: {:noreply, %{s | bots: Map.delete(s.bots, name)}}

  @impl true
  def handle_call(:list, _from, s), do: {:reply, s.bots, s}

  @impl true
  def handle_info(:check, s) do
    instances = Druzhok.InstanceManager.list() |> Map.new(&{&1.name, &1})

    results =
      s.bots
      |> Map.keys()
      |> Task.async_stream(
        fn name ->
          case instances[name] do
            nil -> {name, {:down, {:unit, :unknown}}}
            inst -> {name, Druzhok.HealthMonitor.Probe.run(inst)}
          end
        end,
        timeout: @probe_timeout,
        on_timeout: :kill_task,
        max_concurrency: 4
      )
      |> Enum.flat_map(fn
        {:ok, {name, res}} -> [{name, res}]
        {:exit, _} -> []
      end)

    bots =
      Enum.reduce(results, s.bots, fn {name, res}, acc ->
        Map.update!(acc, name, &apply_result(name, &1, res))
      end)

    schedule()
    {:noreply, %{s | bots: bots}}
  end

  defp apply_result(name, info, {:healthy, []}) do
    if info.status != :healthy, do: Logger.info("Bot #{name} healthy again")
    %{info | status: :healthy, reasons: [], failures: 0, checked_at: DateTime.utc_now()}
  end

  defp apply_result(name, info, {:degraded, reasons}) do
    if info.status != :degraded or info.reasons != reasons, do: log(name, "degraded", reasons)
    %{info | status: :degraded, reasons: reasons, failures: 0, checked_at: DateTime.utc_now()}
  end

  defp apply_result(name, info, {:down, reason}) do
    failures = info.failures + 1
    if info.status != :down, do: log(name, "down", [reason])
    Logger.warning("Bot #{name} down (#{failures}/#{@max_failures}): #{inspect(reason)}")

    if failures >= @max_failures do
      Druzhok.Events.broadcast(name, %{type: :health_restart})
      Task.start(fn -> Druzhok.BotManager.restart(name) end)
      %{info | status: :down, reasons: [reason], failures: 0, checked_at: DateTime.utc_now()}
    else
      %{info | status: :down, reasons: [reason], failures: failures, checked_at: DateTime.utc_now()}
    end
  end

  defp log(name, level_word, reasons) do
    Druzhok.CrashLog.insert(%{
      level: if(level_word == "down", do: "error", else: "warning"),
      message: "Bot #{name} #{level_word}: #{inspect(reasons)}",
      source: "Druzhok.HealthMonitor",
      instance_name: name
    })
  end

  defp schedule, do: Process.send_after(self(), :check, @interval)
end
