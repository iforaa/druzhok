defmodule Druzhok.HealthMonitor do
  @moduledoc """
  Periodically polls health of each running bot container.
  Restarts containers that fail 3 consecutive health checks.
  """
  use GenServer
  require Logger

  @check_interval 30_000
  @max_failures 3

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def register(name, container_id, bot_runtime \\ "zeroclaw") do
    GenServer.cast(__MODULE__, {:register, name, container_id, bot_runtime})
  end

  def unregister(name) do
    GenServer.cast(__MODULE__, {:unregister, name})
  end

  def list do
    GenServer.call(__MODULE__, :list)
  end

  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %{bots: %{}}}
  end

  @impl true
  def handle_cast({:register, name, container_id, bot_runtime}, state) do
    bots = Map.put(state.bots, name, %{container_id: container_id, bot_runtime: bot_runtime, failures: 0, status: :healthy})
    {:noreply, %{state | bots: bots}}
  end

  @impl true
  def handle_cast({:unregister, name}, state) do
    {:noreply, %{state | bots: Map.delete(state.bots, name)}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state.bots, state}
  end

  @impl true
  def handle_info(:check_health, state) do
    bots =
      state.bots
      |> Enum.map(fn {name, info} -> {name, check_one(name, info)} end)
      |> Map.new()

    schedule_check()
    {:noreply, %{state | bots: bots}}
  end

  defp check_one(name, info) do
    case do_health_check(info.container_id) do
      :ok ->
        if info.failures > 0, do: Logger.info("Bot #{name} recovered")
        %{info | failures: 0, status: :healthy}

      :error ->
        failures = info.failures + 1
        Logger.warning("Bot #{name} health check failed (#{failures}/#{@max_failures})")

        if failures >= @max_failures do
          Logger.error("Bot #{name} unhealthy, attempting restart")
          Druzhok.Events.broadcast(name, %{type: :health_restart})
          Task.start(fn -> Druzhok.BotManager.restart(name) end)
          %{info | failures: 0, status: :restarting}
        else
          %{info | failures: failures, status: :degraded}
        end
    end
  end

  defp do_health_check(container) do
    case System.cmd("docker", ["inspect", "--format", "{{.State.Running}}", container], stderr_to_stdout: true) do
      {"true\n", 0} -> :ok
      _ -> :error
    end
  end

  defp schedule_check do
    Process.send_after(self(), :check_health, @check_interval)
  end
end
