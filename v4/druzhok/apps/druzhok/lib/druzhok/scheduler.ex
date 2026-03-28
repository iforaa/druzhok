defmodule Druzhok.Scheduler do
  @moduledoc """
  Per-instance scheduler. In v4, this manages the heartbeat timer.
  The bot runtime handles the actual heartbeat execution internally.
  """
  use GenServer
  require Logger

  defstruct [
    :instance_name,
    :workspace,
    :heartbeat_interval,  # minutes, 0 = disabled
    :heartbeat_timer,
  ]

  def start_link(opts) do
    case opts[:registry_name] do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def set_heartbeat_interval(pid, minutes) do
    GenServer.cast(pid, {:set_heartbeat_interval, minutes})
  end

  def init(opts) do
    state = %__MODULE__{
      instance_name: opts.instance_name,
      workspace: opts.workspace,
      heartbeat_interval: opts[:heartbeat_interval] || 0,
    }

    state = schedule_heartbeat(state)
    {:ok, state}
  end

  def handle_cast({:set_heartbeat_interval, minutes}, state) do
    if state.heartbeat_timer, do: Process.cancel_timer(state.heartbeat_timer)

    state = %{state | heartbeat_interval: minutes, heartbeat_timer: nil}
    state = schedule_heartbeat(state)

    case Druzhok.Repo.get_by(Druzhok.Instance, name: state.instance_name) do
      nil -> :ok
      inst -> Druzhok.Repo.update(Druzhok.Instance.changeset(inst, %{heartbeat_interval: minutes}))
    end

    Logger.info("[#{state.instance_name}] Heartbeat interval set to #{minutes}m")
    {:noreply, state}
  end

  def handle_info(:heartbeat_tick, state) do
    name = state.instance_name
    Logger.info("[#{name}] Heartbeat tick — handled by bot internally")
    Druzhok.Events.broadcast(name, %{type: :heartbeat, text: "Heartbeat tick"})

    state = schedule_heartbeat(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_heartbeat(%{heartbeat_interval: 0} = state), do: state
  defp schedule_heartbeat(%{heartbeat_interval: minutes} = state) when minutes > 0 do
    timer = Process.send_after(self(), :heartbeat_tick, minutes * 60_000)
    %{state | heartbeat_timer: timer}
  end
end
