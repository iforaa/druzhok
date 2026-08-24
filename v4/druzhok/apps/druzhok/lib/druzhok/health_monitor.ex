defmodule Druzhok.HealthMonitor do
  @moduledoc """
  Runs `Druzhok.HealthMonitor.Probe` for every registered bot every 60 s.
  Three consecutive `:down` results restart the bot. Every transition into
  degraded/down is recorded in `crash_logs` so /errors is the alert feed.

  The sweep runs in a linked Task so `list/0` (polled by the dashboard) never
  waits behind slow probes. The LLM ping is a real, metered completion on the
  bot's own model, so it only runs every `@llm_every` sweeps; in between the
  last LLM result is reused.
  """
  use GenServer
  require Logger

  @interval 60_000
  @max_failures 3
  @probe_timeout 20_000
  @llm_every 5

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def register(name), do: GenServer.cast(__MODULE__, {:register, name})
  def unregister(name), do: GenServer.cast(__MODULE__, {:unregister, name})
  def list, do: GenServer.call(__MODULE__, :list)

  @impl true
  def init(_) do
    schedule()
    {:ok, %{bots: %{}, tick: 0, sweep: nil}}
  end

  @impl true
  def handle_cast({:register, name}, s) do
    entry = %{status: :healthy, reasons: [], failures: 0, llm: :ok}
    {:noreply, put_in(s, [:bots, name], entry)}
  end

  def handle_cast({:unregister, name}, s), do: {:noreply, %{s | bots: Map.delete(s.bots, name)}}

  @impl true
  def handle_call(:list, _from, s), do: {:reply, s.bots, s}

  @impl true
  def handle_info(:check, %{sweep: nil} = s) do
    tick = s.tick + 1
    bots = s.bots
    llm_tick? = rem(tick, @llm_every) == 0
    task = Task.async(fn -> sweep(bots, llm_tick?) end)
    {:noreply, %{s | tick: tick, sweep: task}}
  end

  # Previous sweep still running — skip this tick rather than pile up.
  def handle_info(:check, s) do
    schedule()
    {:noreply, s}
  end

  def handle_info({ref, results}, %{sweep: %Task{ref: ref}} = s) do
    Process.demonitor(ref, [:flush])

    bots =
      Enum.reduce(results, s.bots, fn {name, res, llm}, acc ->
        # The bot may have been unregistered while the sweep ran.
        case acc do
          %{^name => info} -> Map.put(acc, name, apply_result(name, %{info | llm: llm}, res))
          _ -> acc
        end
      end)

    schedule()
    {:noreply, %{s | bots: bots, sweep: nil}}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{sweep: %Task{ref: ref}} = s) do
    Logger.error("HealthMonitor sweep crashed: #{inspect(reason)}")
    schedule()
    {:noreply, %{s | sweep: nil}}
  end

  def handle_info(_, s), do: {:noreply, s}

  # Returns [{name, probe_result, llm_result}].
  defp sweep(bots, llm_tick?) do
    instances = Druzhok.InstanceManager.list() |> Map.new(&{&1.name, &1})

    bots
    |> Task.async_stream(
      fn {name, info} ->
        case instances[name] do
          nil ->
            {name, {:down, {:unit, :unknown}}, info.llm}

          inst ->
            llm = if llm_tick?, do: Druzhok.HealthMonitor.Probe.llm_ping(inst), else: info.llm
            {name, Druzhok.HealthMonitor.Probe.run(inst, llm_ping: fn _ -> llm end), llm}
        end
      end,
      timeout: @probe_timeout,
      on_timeout: :kill_task,
      max_concurrency: 4
    )
    |> Enum.flat_map(fn
      {:ok, res} -> [res]
      {:exit, _} -> []
    end)
  end

  defp apply_result(name, info, {:healthy, []}) do
    if info.status != :healthy, do: Logger.info("Bot #{name} healthy again")
    %{info | status: :healthy, reasons: [], failures: 0}
  end

  defp apply_result(name, info, {:degraded, reasons}) do
    if info.status != :degraded or info.reasons != reasons, do: log(name, :degraded, reasons)
    %{info | status: :degraded, reasons: reasons, failures: 0}
  end

  defp apply_result(name, info, {:down, reason}) do
    failures = info.failures + 1
    if info.status != :down, do: log(name, :down, [reason])
    Logger.warning("Bot #{name} down (#{failures}/#{@max_failures}): #{inspect(reason)}")

    if failures >= @max_failures do
      Druzhok.Events.broadcast(name, %{type: :health_restart})
      Task.start(fn -> Druzhok.BotManager.restart(name) end)
      %{info | status: :down, reasons: [reason], failures: 0}
    else
      %{info | status: :down, reasons: [reason], failures: failures}
    end
  end

  defp log(name, status, reasons) do
    Druzhok.CrashLog.insert(%{
      level: if(status == :down, do: "error", else: "warning"),
      message: "Bot #{name} #{status}: #{inspect(reasons)}",
      source: "Druzhok.HealthMonitor",
      instance_name: name
    })
  end

  defp schedule, do: Process.send_after(self(), :check, @interval)
end
