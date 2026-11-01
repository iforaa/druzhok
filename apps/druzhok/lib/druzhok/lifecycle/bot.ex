defmodule Druzhok.Lifecycle.Bot do
  @moduledoc """
  One bot's lifecycle controller (sleep/wake spec, "Controller"). The only
  code that calls `Host.start/stop/destroy` for its bot or writes the
  controller columns of its row. It does one action at a time and, on every
  pass, applies the first rule that holds:

  1. row gone → exit
  2. unit stopping → wait
  3. `delete_requested` → stop, destroy, exit (a failed destroy is recorded
     and retried on the backoff)
  4. `!active` → stop, acknowledge the stop
  5. asleep → wake when there is a reason
  6. awake → recover a restart loop, start when down or asked, apply saved
     panel settings at a quiet moment, sleep when idle

  A wake and the start of a down unit go through `StartGate`; a refused one
  changes nothing and is tried again on the next tick. A restart of a running
  unit does not: it already holds its memory.

  It keeps nothing that matters outside the row and the unit, so a new
  controller after a crash just applies the rules again.
  """

  use GenServer, restart: :transient
  require Logger
  alias Druzhok.{BotManager, Host, Instance, Repo}
  alias Druzhok.Lifecycle.{Idle, StartGate, Typing}
  alias Druzhok.Telegram.{Addressed, Inbox, Relay, Webhook}

  def key(instance_id), do: {:lifecycle, instance_id}

  def start_link(instance_id),
    do:
      GenServer.start_link(__MODULE__, instance_id,
        name: {:via, Registry, {Druzhok.Registry, key(instance_id)}}
      )

  @impl true
  def init(id) do
    send(self(), :poke)

    {:ok,
     %{
       id: id,
       unit: nil,
       unit_at: nil,
       activating_since: nil,
       idle_at: nil,
       quiet_at: nil,
       waiting_since: nil,
       wait_warned: false,
       lock_refused: false,
       timer: nil
     }}
  end

  @impl true
  # While a start waits at the gate the relay pokes every 2 s; the unit is
  # re-read every unit_poll_ms instead, or each waiting bot runs `sudo
  # druzhok-ctl status` on every poke.
  def handle_info(:poke, state) do
    flush(:poke)
    pass(if gate_refused?(state), do: state, else: %{state | unit_at: nil})
  end

  def handle_info(:tick, state), do: pass(state)
  def handle_info(_, state), do: {:noreply, state}

  defp flush(msg) do
    receive do
      ^msg -> flush(msg)
    after
      0 -> :ok
    end
  end

  defp pass(state) do
    case Repo.get(Instance, state.id) do
      nil ->
        {:stop, :normal, state}

      inst ->
        state = observe(state, inst)

        case rule(state, inst) do
          {:stop, state} ->
            {:stop, :normal, state}

          state ->
            # One tick chain only: a poke's pass replaces the pending tick.
            if state.timer, do: Process.cancel_timer(state.timer)
            {:noreply, %{state | timer: Process.send_after(self(), :tick, opt(:tick_ms))}}
        end
    end
  end

  # --- rules ------------------------------------------------------------------

  defp rule(%{unit: :stopping} = state, _inst), do: state

  defp rule(state, %Instance{delete_requested: true} = inst) do
    state =
      if down?(state.unit), do: state, else: act(state, fn -> stop_unit(inst, :stopping) end)

    cond do
      not down?(state.unit) ->
        state

      not delete_backoff_over?(inst) ->
        state

      true ->
        case destroy(inst) do
          :ok ->
            Logger.info("[life] #{inst.name}: deleted")
            {:stop, state}

          {:error, reason} ->
            record_delete_failure(inst, reason)
            refresh(state, inst)
        end
    end
  end

  defp rule(state, %Instance{active: false} = inst) do
    state =
      if down?(state.unit) do
        state
      else
        act(state, fn ->
          stop_unit(inst, :stopping)
          Logger.info("[life] #{inst.name}: stopped")
        end)
      end

    if inst.sleeping, do: set(inst, sleeping: false)

    if down?(state.unit) and inst.stopped_seq < inst.stop_seq,
      do: set(inst, stopped_seq: inst.stop_seq)

    state
  end

  defp rule(state, %Instance{sleeping: true} = inst) do
    cond do
      state.unit in [:active, :activating, :restarting] ->
        # Someone started the unit by hand: it is awake now.
        set(inst, sleeping: false)
        state

      reason = wake_reason(inst) ->
        # Refused, the row stays asleep: the relay keeps holding updates.
        through_gate(state, inst, fn ->
          Logger.info("[life] #{inst.name}: waking (#{describe(reason, inst)})")
          set(inst, sleeping: false, woke_at: now())
          if reason == :update, do: Typing.start(inst)
          start_action(state, inst)
        end)

      true ->
        end_wait(state)
    end
  end

  defp rule(state, inst) do
    cond do
      state.unit == :restarting ->
        loop_failure(state, inst, "restart loop")

      state.unit == :activating and stuck_activating?(state) ->
        loop_failure(state, inst, "start timeout")

      state.unit == :activating ->
        state

      down?(state.unit) or inst.start_seq > inst.applied_seq ->
        cond do
          not backoff_over?(inst) -> state
          down?(state.unit) -> through_gate(state, inst, fn -> start_action(state, inst) end)
          true -> start_action(state, inst)
        end

      state.unit == :active ->
        awake(state, inst)

      true ->
        state
    end
  end

  # Busy is not a failure: nothing is recorded, and the next tick tries again.
  defp through_gate(state, inst, start) do
    case StartGate.with_slot(start) do
      {:busy, :lock} -> %{state | lock_refused: true}
      {:busy, {:memory, free}} -> wait_for_memory(%{state | lock_refused: false}, inst, free)
      %{} = state -> end_wait(state)
    end
  end

  defp gate_refused?(state), do: is_integer(state.waiting_since) or state.lock_refused

  defp end_wait(state), do: %{state | waiting_since: nil, lock_refused: false}

  defp wait_for_memory(%{waiting_since: nil} = state, inst, free) do
    Logger.info("[life] #{inst.name}: start waits (free #{free} MB)")
    %{state | waiting_since: System.monotonic_time(:millisecond), wait_warned: false}
  end

  defp wait_for_memory(%{wait_warned: false} = state, inst, free) do
    waited = System.monotonic_time(:millisecond) - state.waiting_since

    if waited >= opt(:wait_warn_ms) do
      Logger.warning(
        "[life] #{inst.name}: start has waited #{div(waited, 60_000)} min for memory " <>
          "(free #{free} MB); held updates expire at 24 h"
      )

      %{state | wait_warned: true}
    else
      state
    end
  end

  defp wait_for_memory(state, _inst, _free), do: state

  defp awake(state, inst) do
    if is_nil(inst.started_at), do: set(inst, started_at: now())

    cond do
      settings_pending?(inst) -> apply_settings(state, inst)
      idle_check_due?(state) -> sleep_check(state, inst)
      true -> state
    end
  end

  defp sleep_check(state, inst) do
    state = %{state | idle_at: System.monotonic_time(:millisecond)}

    case Idle.check(inst) do
      :idle ->
        sleep_action(state, inst)

      {:busy, _} ->
        resume_stale_hold(inst)
        state
    end
  end

  # A hold an interrupted action of ours left behind; the unit is up and
  # settled, so nothing is draining behind it. Left in place it would also
  # keep updates unacknowledged, which reads as busy forever.
  defp resume_stale_hold(inst) do
    if inst.telegram_relay_pause_reason in ["stopping", "sleeping"],
      do: Webhook.resume_if(inst.id, inst.telegram_relay_pause_reason)
  end

  defp settings_pending?(inst), do: (inst.settings_seq || 0) > (inst.settings_applied_seq || 0)

  # Panel controls spec, «A quiet restart»: settings the owner saved in the
  # panel reach hermes only through a restart, which must not cut off an
  # answer or kill a job the agent started. So: no Telegram update and no
  # proxy call for a minute, no turn, no process besides hermes; then hold
  # the relay, let a delivery in flight land and look again. Never forced: a
  # bot that is never quiet keeps the change until it is. While a change waits
  # an awake bot does not fall asleep (an idle bot is quiet, so it restarts
  # instead); only a bot already asleep at the save applies it on its wake.
  @quiet [:telegram, :proxy, :turns, :processes]

  defp apply_settings(state, inst) do
    if quiet_check_due?(state) do
      state = %{state | quiet_at: System.monotonic_time(:millisecond)}

      if quiet?(inst) do
        hold(inst.id, :stopping)
        Relay.quiesce(inst.id)
        latest = Repo.get(Instance, inst.id)

        if latest && settings_pending?(latest) && quiet?(latest) do
          Logger.info("[life] #{inst.name}: applying saved settings")
          start_action(state, latest)
        else
          Webhook.resume_if(inst.id, :stopping)
          Relay.notify(inst.id)
          state
        end
      else
        resume_stale_hold(inst)
        state
      end
    else
      state
    end
  end

  defp quiet?(inst), do: Idle.check(inst, window_s: opt(:quiet_window_s), only: @quiet) == :idle

  defp quiet_check_due?(%{quiet_at: nil}), do: true

  defp quiet_check_due?(%{quiet_at: at}),
    do: System.monotonic_time(:millisecond) - at >= opt(:quiet_check_ms)

  defp describe(:update, inst) do
    case Inbox.next_waking(inst.id) do
      %Inbox{update_id: id} -> "update #{id}"
      _ -> "update"
    end
  end

  defp describe(reason, _inst), do: to_string(reason)

  defp wake_reason(inst) do
    cond do
      Inbox.next_waking(inst.id) -> :update
      inst.start_seq > inst.applied_seq -> :requested
      cron_due?(inst) -> :cron
      not inst.sleep_enabled -> :sleep_disabled
      inst.telegram_mode != "webhook" or inst.telegram_mode != inst.started_mode -> :mode
      true -> nil
    end
  end

  # An unreadable jobs file wakes the bot: it cannot be asleep through a run
  # no one can see.
  defp cron_due?(inst) do
    case Idle.cron_wake_at(inst) do
      {:ok, nil} -> false
      {:ok, at} -> DateTime.compare(at, DateTime.utc_now()) != :gt
      :error -> true
    end
  end

  # --- actions ----------------------------------------------------------------

  defp start_action(state, inst) do
    inst = Repo.get(Instance, inst.id)

    if runnable?(inst) do
      seq = inst.start_seq
      # The panel settings this start carries; a save after this read stays pending.
      settings = inst.settings_seq || 0
      started = System.monotonic_time(:millisecond)
      set(inst, started_at: now(), started_mode: inst.telegram_mode)

      state =
        if state.unit in [:inactive, :unknown],
          do: state,
          else: act(state, fn -> stop_unit(inst, :stopping) end)

      # A stop that did not take (it raised, or the unit still drains) is
      # retried by the next pass; starting now would keep the old hermes.
      if down?(state.unit), do: run_start(state, inst, {seq, settings}, started), else: state
    else
      state
    end
  end

  defp run_start(state, inst, {seq, settings}, started) do
    {env, data_root} = BotManager.prepare_start(inst)
    latest = Repo.get(Instance, inst.id)

    # A Stop made during the drain or the file writes wins before Host.start.
    if runnable?(latest) do
      case Host.start(inst.name, env, data_root) do
        :ok ->
          case Host.status(inst.name) do
            :active -> started(state, inst, {seq, settings}, started)
            other -> failed(state, inst, seq, "unit #{other} after start")
          end

        {:error, reason} ->
          failed(state, inst, seq, inspect(reason))
      end
    else
      refresh(state, inst)
    end
  rescue
    e -> failed(state, inst, seq, Exception.message(e))
  catch
    :exit, reason -> failed(state, inst, seq, "exit: #{inspect(reason)}")
  end

  defp runnable?(%Instance{active: true, delete_requested: false}), do: true
  defp runnable?(_), do: false

  defp started(state, inst, {seq, settings}, t0) do
    set(inst,
      applied_seq: seq,
      settings_applied_seq: settings,
      start_error: nil,
      start_failed_at: nil,
      start_failures: 0
    )

    # A restart is how a rejected_config pause gets fixed; a foreign process
    # on the port is not.
    Webhook.resume_except(inst.id, :wrong_owner)
    Relay.notify(inst.id)
    # A cast: it cannot block this start or raise into run_start's rescue.
    Druzhok.Cabinet.sync(inst.id)

    Logger.info(
      "[life] #{inst.name}: started in #{div(System.monotonic_time(:millisecond) - t0, 1000)} s"
    )

    refresh(state, inst)
  end

  defp failed(state, inst, seq, reason) do
    record_failure(inst, reason, failed_seq: max(seq, inst.failed_seq))
    # Stop what systemd would otherwise cycle every RestartSec behind our backoff.
    act(state, fn -> stop_unit(inst, :stopping) end)
  end

  # A loop the controller did not start itself (a crash after READY whose
  # restarts die, a druzhok restart during Host.start, druzhok-ctl by hand).
  # No request of anyone's was attempted, so failed_seq moves only up to what
  # is already applied.
  defp loop_failure(state, inst, reason) do
    record_failure(inst, reason, failed_seq: max(inst.failed_seq, inst.applied_seq))
    act(%{state | activating_since: nil}, fn -> stop_unit(inst, :stopping) end)
  end

  defp record_failure(inst, reason, extra) do
    n = (inst.start_failures || 0) + 1
    reason = String.slice(to_string(reason), 0, 500)

    set(
      inst,
      [start_error: reason, start_failed_at: DateTime.utc_now(), start_failures: n] ++ extra
    )

    Logger.error(
      "[life] #{inst.name}: start failed (#{n}): #{reason}, next try in #{div(backoff_ms(n), 1000)} s"
    )
  end

  # Every step of destroy_instance is idempotent, so a failure (its own error
  # or a raise) is retried whole after the backoff.
  defp destroy(inst) do
    BotManager.destroy_instance(inst)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    :exit, reason -> {:error, "exit: #{inspect(reason)}"}
  end

  defp record_delete_failure(inst, reason) do
    n = (inst.delete_failures || 0) + 1
    reason = reason |> describe_error() |> String.slice(0, 500)
    set(inst, delete_error: reason, delete_failed_at: DateTime.utc_now(), delete_failures: n)

    Logger.error(
      "[life] #{inst.name}: delete failed: #{reason}, next try in #{div(backoff_ms(n), 1000)} s"
    )
  end

  defp describe_error({:ruoc_suspend, reason}), do: "ruoc suspend: #{reason}"
  defp describe_error({:ruoc_sites, reason}), do: "ruoc sites: #{reason}"
  defp describe_error(reason) when is_binary(reason), do: reason
  defp describe_error(reason), do: inspect(reason)

  defp sleep_action(state, inst) do
    hold(inst.id, :sleeping)
    Relay.quiesce(inst.id)
    inst = Repo.get(Instance, inst.id)
    state = refresh(state, inst)

    if inst && state.unit == :active && Idle.check(inst, own_pause: true) == :idle do
      mem = Host.stats(inst.name)

      state =
        act(state, fn ->
          Host.stop(inst.name)
          set(inst, sleeping: true)
        end)

      # Learn the @username now, so the first group message while asleep is
      # judged by it rather than woken by any @mention (Telegram.Addressed).
      Addressed.username(inst)

      Logger.info(
        "[life] #{inst.name}: asleep after #{div(Idle.window_s(), 60)} min idle#{rss(mem)}"
      )

      Webhook.resume_if(inst.id, :sleeping)
      Relay.notify(inst.id)
      state
    else
      Webhook.resume_if(inst.id, :sleeping)
      Relay.notify(inst.id)
      state
    end
  end

  defp rss(%{mem_bytes: b}), do: " (rss #{div(b, 1024 * 1024)} MB)"
  defp rss(_), do: ""

  # Every stop: hold the relay, let a delivery in flight finish, then stop.
  # A pause the relay set (wrong_owner, rejected_config) already holds it and
  # is kept, so the start that follows decides about it, not this stop.
  defp stop_unit(inst, reason) do
    hold(inst.id, reason)
    Relay.quiesce(inst.id)
    Host.stop(inst.name)
  end

  defp hold(id, reason) do
    case Repo.get(Instance, id) |> then(&(&1 && Webhook.paused(&1))) do
      {held, _} when held not in ["stopping", "sleeping"] -> :ok
      _ -> Webhook.pause(id, reason)
    end
  end

  # Run an action without letting it crash the controller; re-read the unit
  # afterwards whatever happened.
  defp act(state, fun) do
    try do
      fun.()
    rescue
      e -> Logger.error("[life] #{state.id}: #{Exception.message(e)}")
    catch
      :exit, reason -> Logger.error("[life] #{state.id}: exit #{inspect(reason)}")
    end

    refresh(state, %{name: name_of(state.id)})
  end

  defp name_of(id), do: Repo.get(Instance, id) |> then(&(&1 && &1.name))

  # --- observation ------------------------------------------------------------

  defp observe(state, inst) do
    state = end_wait_if_unwanted(state, inst)

    state =
      if is_nil(state.unit_at) or
           System.monotonic_time(:millisecond) - state.unit_at >= opt(:unit_poll_ms),
         do: refresh(state, inst),
         else: state

    # Up by other means (druzhok-ctl by hand): nothing is waiting any more.
    if down?(state.unit), do: state, else: end_wait(state)
  end

  # A stop or delete ends the wait and must see the unit as it is now, not as
  # it was at the last unit_poll_ms read: it acts on that, and acknowledges.
  defp end_wait_if_unwanted(state, inst) do
    if gate_refused?(state) and not runnable?(inst),
      do: %{end_wait(state) | unit_at: nil},
      else: state
  end

  defp refresh(state, %{name: nil}), do: state

  defp refresh(state, %{name: name}) do
    unit = Host.status(name)
    now_ms = System.monotonic_time(:millisecond)

    since =
      cond do
        unit != :activating -> nil
        state.activating_since -> state.activating_since
        true -> now_ms
      end

    %{state | unit: unit, unit_at: now_ms, activating_since: since}
  end

  defp refresh(state, nil), do: state

  defp down?(unit), do: unit in [:inactive, :failed, :unknown]

  defp stuck_activating?(%{activating_since: since}) when is_integer(since),
    do: System.monotonic_time(:millisecond) - since > opt(:activating_limit_ms)

  defp stuck_activating?(_), do: false

  defp idle_check_due?(%{idle_at: nil}), do: true

  defp idle_check_due?(%{idle_at: at}),
    do: System.monotonic_time(:millisecond) - at >= opt(:idle_check_ms)

  # 10 s, 1 min, 5 min, then every 15 min; a request made after the failure
  # is tried at once.
  defp backoff_over?(%Instance{start_failures: n}) when n in [nil, 0], do: true

  defp backoff_over?(inst) do
    inst.start_seq > inst.failed_seq or
      is_nil(inst.start_failed_at) or
      DateTime.diff(DateTime.utc_now(), inst.start_failed_at, :millisecond) >=
        backoff_ms(inst.start_failures)
  end

  # The same curve for a failed delete; there is no newer request to go at once.
  defp delete_backoff_over?(%Instance{delete_failures: n}) when n in [nil, 0], do: true

  defp delete_backoff_over?(inst) do
    is_nil(inst.delete_failed_at) or
      DateTime.diff(DateTime.utc_now(), inst.delete_failed_at, :millisecond) >=
        backoff_ms(inst.delete_failures)
  end

  defp backoff_ms(n) do
    case opt(:backoff_ms) do
      list when n <= length(list) -> Enum.at(list, n - 1)
      list -> List.last(list)
    end
  end

  defp set(inst, changes) do
    import Ecto.Query, only: [from: 2]
    from(i in Instance, where: i.id == ^inst.id) |> Repo.update_all(set: changes)
    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @defaults [
    tick_ms: 2_000,
    unit_poll_ms: 30_000,
    idle_check_ms: 60_000,
    quiet_check_ms: 10_000,
    quiet_window_s: 60,
    wait_warn_ms: 3_600_000,
    activating_limit_ms: 330_000,
    backoff_ms: [10_000, 60_000, 300_000, 900_000]
  ]

  defp opt(key),
    do: Keyword.get(Application.get_env(:druzhok, :lifecycle, []), key, @defaults[key])
end
