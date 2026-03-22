defmodule Druzhok.Scheduler do
  @moduledoc """
  Per-instance scheduler. Handles:
  - Heartbeat: periodic prompt from HEARTBEAT.md
  - Reminders: fires at specific times, sends prompt to session
  Checks reminders every 30 seconds regardless of heartbeat setting.
  """
  use GenServer
  require Logger

  @reminder_check_ms 30_000

  defstruct [
    :instance_name,
    :session_pid,
    :workspace,
    :heartbeat_interval,  # minutes, 0 = disabled
    :heartbeat_timer,
    :reminder_timer
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
      session_pid: opts[:session_pid],
      workspace: opts.workspace,
      heartbeat_interval: opts[:heartbeat_interval] || 0,
    }

    state = schedule_heartbeat(state)
    state = schedule_reminder_check(state)

    {:ok, state}
  end

  def handle_cast({:set_heartbeat_interval, minutes}, state) do
    # Cancel old timer
    if state.heartbeat_timer, do: Process.cancel_timer(state.heartbeat_timer)

    state = %{state | heartbeat_interval: minutes, heartbeat_timer: nil}
    state = schedule_heartbeat(state)

    # Persist to DB
    case Druzhok.Repo.get_by(Druzhok.Instance, name: state.instance_name) do
      nil -> :ok
      inst -> Druzhok.Repo.update(Druzhok.Instance.changeset(inst, %{heartbeat_interval: minutes}))
    end

    Logger.info("[#{state.instance_name}] Heartbeat interval set to #{minutes}m")
    {:noreply, state}
  end

  # --- Heartbeat ---

  def handle_info(:heartbeat_tick, state) do
    heartbeat_md = Path.join(state.workspace, "HEARTBEAT.md")

    case File.read(heartbeat_md) do
      {:ok, content} ->
        content = String.trim(content)
        # Skip if file is empty or only comments
        if content != "" and not all_comments?(content) do
          Druzhok.Events.broadcast(state.instance_name, %{type: :heartbeat, text: "Heartbeat tick"})
          prompt = "HEARTBEAT\n\n#{content}"
          PiCore.Session.prompt(state.session_pid, prompt)
        end

      {:error, _} -> :ok
    end

    state = schedule_heartbeat(state)
    {:noreply, state}
  end

  # --- Reminders ---

  def handle_info(:check_reminders, state) do
    pending = Druzhok.Reminder.pending(state.instance_name)

    for reminder <- pending do
      Druzhok.Events.broadcast(state.instance_name, %{type: :reminder, text: "Reminder: #{reminder.message}"})
      prompt = "REMINDER: #{reminder.message}"
      PiCore.Session.prompt(state.session_pid, prompt)
      Druzhok.Reminder.mark_fired(reminder.id)
    end

    state = schedule_reminder_check(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp schedule_heartbeat(%{heartbeat_interval: 0} = state), do: state
  defp schedule_heartbeat(%{heartbeat_interval: minutes} = state) when minutes > 0 do
    timer = Process.send_after(self(), :heartbeat_tick, minutes * 60_000)
    %{state | heartbeat_timer: timer}
  end

  defp schedule_reminder_check(state) do
    timer = Process.send_after(self(), :check_reminders, @reminder_check_ms)
    %{state | reminder_timer: timer}
  end

  defp all_comments?(text) do
    text
    |> String.split("\n")
    |> Enum.all?(fn line ->
      trimmed = String.trim(line)
      trimmed == "" or String.starts_with?(trimmed, "<!--") or String.starts_with?(trimmed, "#")
    end)
  end
end
