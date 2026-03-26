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
    :workspace,
    :heartbeat_interval,  # minutes, 0 = disabled
    :heartbeat_timer,
    :reminder_timer,
    :dream_timer,
    :dream_hour
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
      dream_hour: opts[:dream_hour] || -1,
    }

    state = schedule_heartbeat(state)
    state = schedule_reminder_check(state)
    state = schedule_dream_check(state)

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
          case lookup_session(state) do
            nil -> :ok
            pid -> PiCore.Session.prompt_heartbeat(pid, prompt)
          end
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
      pid = lookup_session_for_chat(state, reminder.chat_id)
      if pid, do: PiCore.Session.prompt(pid, prompt)
      Druzhok.Reminder.mark_fired(reminder.id)
    end

    state = schedule_reminder_check(state)
    {:noreply, state}
  end

  # --- Dreaming ---

  def handle_info(:dream_check, state) do
    if should_dream?(state) do
      Logger.info("[#{state.instance_name}] Starting dream session")
      Druzhok.Events.broadcast(state.instance_name, %{type: :dream, text: "Dream session started"})
      run_dream(state)
    end

    state = schedule_dream_check(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Private ---

  defp lookup_session(state) do
    lookup_session_for_chat(state, nil)
  end

  defp lookup_session_for_chat(state, chat_id) do
    # If reminder has a chat_id, use it to find the right session (group or DM)
    # Otherwise fall back to owner's DM session
    target_chat_id = chat_id || owner_chat_id(state)

    if target_chat_id do
      case Registry.lookup(Druzhok.Registry, {state.instance_name, :session, target_chat_id}) do
        [{pid, _}] -> pid
        [] ->
          # Session doesn't exist yet — start one (reminder might fire after restart)
          case Druzhok.Instance.SessionSup.start_session(
            state.instance_name, target_chat_id, %{group: chat_id != nil and chat_id < 0}
          ) do
            {:ok, pid} -> pid
            _ -> nil
          end
      end
    else
      nil
    end
  end

  defp owner_chat_id(state) do
    case Druzhok.Repo.get_by(Druzhok.Instance, name: state.instance_name) do
      %{owner_telegram_id: id} when not is_nil(id) -> id
      _ -> nil
    end
  end

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

  defp should_dream?(%{dream_hour: -1}), do: false
  defp should_dream?(state) do
    current_hour = case DateTime.now(instance_timezone(state)) do
      {:ok, dt} -> dt.hour
      _ -> DateTime.utc_now().hour
    end
    current_hour == state.dream_hour
  end

  defp instance_timezone(state) do
    case Druzhok.Repo.get_by(Druzhok.Instance, name: state.instance_name) do
      %{timezone: tz} when tz != nil and tz != "" -> tz
      _ -> "UTC"
    end
  end

  defp run_dream(state) do
    dream_md = Path.join(state.workspace, "DREAM.md")

    case File.read(dream_md) do
      {:ok, template} ->
        template = String.trim(template)
        if template != "" do
          digest = Druzhok.DreamDigest.build(state.workspace)
          prompt = String.replace(template, "{CONVERSATIONS}", digest)

          config = :persistent_term.get({:druzhok_session_config, state.instance_name}, nil)
          if config do
            Task.start(fn ->
              case PiCore.Session.start_link(%{
                workspace: config.workspace,
                model: config.model,
                provider: config[:provider],
                api_url: config.api_url,
                api_key: config.api_key,
                instance_name: state.instance_name,
                on_delta: nil,
                on_event: nil,
                tools: dream_tools(),
                extra_tool_context: %{workspace: config.workspace, instance_name: state.instance_name},
                timezone: config[:timezone] || "UTC"
              }) do
                {:ok, pid} ->
                  PiCore.Session.prompt(pid, prompt)
                  Process.sleep(120_000)
                  Process.exit(pid, :normal)
                {:error, reason} ->
                  Logger.warning("[#{state.instance_name}] Dream session failed: #{inspect(reason)}")
              end
            end)
          end
        end

      {:error, _} -> :ok
    end
  end

  defp dream_tools do
    [
      PiCore.Tools.Read.new(),
      PiCore.Tools.Write.new(),
      PiCore.Tools.Edit.new(),
      PiCore.Tools.Find.new(),
      PiCore.Tools.Grep.new(),
      PiCore.Tools.MemorySearch.new(),
      PiCore.Tools.MemoryWrite.new(),
    ]
  end

  defp schedule_dream_check(%{dream_hour: -1} = state), do: state
  defp schedule_dream_check(state) do
    timer = Process.send_after(self(), :dream_check, 3_600_000)
    %{state | dream_timer: timer}
  end
end
