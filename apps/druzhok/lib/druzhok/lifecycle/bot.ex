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

  Queue mode (`Lifecycle.Queue`, bot queue spec) changes four things. An
  asleep bot wakes only on a grant from `Lifecycle.Scheduler`, and only if,
  inside the one-start lock, the slots still have room. An awake bot whose
  unit is down, or whose start failed, goes back to sleep and so into the
  line. A switch asked by the scheduler holds deliveries, waits for the bot
  to finish (`switch_action`), at most `max_drain_s`, and stops it. And an
  asleep or stopped bot whose unit was last seen inactive no longer reads it
  every 30 s: the scheduler's sweep points it at a unit that runs.
  """

  use GenServer, restart: :transient
  require Logger
  alias Druzhok.{BotManager, Host, Instance, Repo}
  alias Druzhok.Lifecycle.{Idle, Queue, Scheduler, StartGate, Typing, Wake}
  alias Druzhok.Telegram.{Addressed, API, Inbox, Relay, Webhook}

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
       timer: nil,
       # Queue mode: read once a pass; a grant or a switch request this pass;
       # the switch in progress; a unit to read whatever the last one said.
       queue: false,
       grant: false,
       switch_req: nil,
       switch: nil,
       force_unit: false
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

  # Queue mode: the scheduler's one attempt to wake this bot, its request to
  # make room, and its sweep finding this bot's unit running.
  def handle_info(:grant, state), do: pass(%{state | grant: true, unit_at: nil})
  def handle_info({:switch, rule}, state), do: pass(%{state | switch_req: rule})
  def handle_info(:unit_running, state), do: pass(%{state | force_unit: true, unit_at: nil})
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
        {:stop, :normal, answer_scheduler(state)}

      inst ->
        state = %{state | queue: Queue.on?()} |> carry_on_switch(inst) |> observe(inst)

        case rule(state, inst) do
          {:stop, state} ->
            {:stop, :normal, answer_scheduler(state)}

          state ->
            state = answer_scheduler(state)
            # One tick chain only: a poke's pass replaces the pending tick.
            if state.timer, do: Process.cancel_timer(state.timer)
            {:noreply, %{state | timer: Process.send_after(self(), :tick, opt(:tick_ms))}}
        end
    end
  end

  # A grant is one attempt: used or dropped, the scheduler hears at the end
  # of the pass. A switch request that did not start a switch is dropped too;
  # one that did is answered when the switch ends.
  defp answer_scheduler(state) do
    if state.grant, do: Scheduler.grant_done(state.id, state.grant == :used)
    if state.switch_req && is_nil(state.switch), do: Scheduler.switch_done(state.id)
    %{state | grant: false, switch_req: nil, force_unit: false}
  end

  # --- rules ------------------------------------------------------------------

  defp rule(%{unit: :stopping} = state, _inst), do: state

  defp rule(state, %Instance{delete_requested: true} = inst) do
    state = abandon_switch(state, inst)

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
    state = abandon_switch(state, inst)

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
    # A switch that stopped the bot and was cut off before lifting its hold.
    if match?({"switching", _}, Webhook.paused(inst)), do: Webhook.resume_if(inst.id, :switching)

    cond do
      state.unit in [:active, :activating, :restarting] ->
        # Someone started the unit by hand: it is awake now.
        set(inst, sleeping: false)
        state

      state.queue ->
        # Only the scheduler wakes a bot in queue mode; a relay poke is a no-op.
        if state.grant, do: granted_wake(state, inst), else: state

      reason = Wake.reason(inst) ->
        # Refused, the row stays asleep: the relay keeps holding updates.
        through_gate(state, inst, fn -> wake(state, inst, reason) end)

      true ->
        end_wait(state)
    end
  end

  defp rule(state, inst) do
    cond do
      # While a switch runs nothing else does: a restart request or saved
      # panel settings wait, as they do for an asleep bot, so nothing lifts
      # the hold mid-drain.
      state.switch ->
        switch_step(state, inst)

      state.queue and state.unit in [:inactive, :failed] ->
        # Crashed, or druzhok restarted during a start: back through the line.
        Logger.info("[queue] #{inst.name}: unit #{state.unit}, back in the line")
        set(inst, sleeping: true)
        state

      state.queue and state.unit == :unknown ->
        # A failed status read is no news: read again next pass rather than
        # give up the slot of a bot that may well be running, or start it
        # past the line.
        %{state | unit_at: nil}

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

      state.unit == :active and not is_nil(state.switch_req) ->
        switch_action(state, inst, state.switch_req)

      state.unit == :active ->
        awake(state, inst)

      true ->
        state
    end
  end

  defp wake(state, inst, reason) do
    Logger.info("[life] #{inst.name}: waking (#{describe(reason, inst)})")
    set(inst, sleeping: false, woke_at: now())
    if reason == :update, do: Typing.start(inst)
    start_action(state, inst)
  end

  # The scheduler's grant is one attempt. The reason is read again (rows
  # dropped or expired meanwhile end it), and the slots are counted again
  # inside the one-start lock, so two grants can never both get through.
  # Refused, nothing changes: the bot stays asleep and in the line.
  defp granted_wake(state, inst) do
    reason = Wake.reason(inst, queue: true)

    cond do
      is_nil(reason) or not backoff_over?(inst) ->
        state

      true ->
        start = fn ->
          if Scheduler.room?(), do: wake(state, inst, reason), else: {:busy, :full}
        end

        case StartGate.with_slot(start) do
          {:busy, why} ->
            Logger.info("[queue] #{inst.name}: grant dropped (#{inspect(why)})")
            state

          %{} = state ->
            %{state | grant: :used}
        end
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

    case Idle.check(inst, queue: state.queue) do
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
    state |> act(fn -> stop_unit(inst, :stopping) end) |> give_slot_back(inst)
  end

  # A loop the controller did not start itself (a crash after READY whose
  # restarts die, a druzhok restart during Host.start, druzhok-ctl by hand).
  # No request of anyone's was attempted, so failed_seq moves only up to what
  # is already applied.
  defp loop_failure(state, inst, reason) do
    record_failure(inst, reason, failed_seq: max(inst.failed_seq, inst.applied_seq))

    %{state | activating_since: nil}
    |> act(fn -> stop_unit(inst, :stopping) end)
    |> give_slot_back(inst)
  end

  # Queue mode: a failed start sleeps once its unit is down, so its slot goes
  # to the line; it comes back as `:retry` after the backoff.
  defp give_slot_back(state, inst) do
    if state.queue and state.unit in [:inactive, :failed], do: set(inst, sleeping: true)
    state
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

    if inst && state.unit == :active &&
         Idle.check(inst, own_pause: true, queue: state.queue) == :idle do
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

      warn_unreadable_jobs(state, inst)
      Webhook.resume_if(inst.id, :sleeping)
      Relay.notify(inst.id)
      state
    else
      Webhook.resume_if(inst.id, :sleeping)
      Relay.notify(inst.id)
      state
    end
  end

  # --- switch (queue mode) ----------------------------------------------------

  @cap_text "Задача заняла слишком много времени и была остановлена, чтобы ответить другим. " <>
              "Напишите ещё раз, если она нужна."

  # Bot queue spec, "Switch": hold first, so a quiet moment must come. The
  # hold outlasts the whole drain and a slow stop; the default 5 min would
  # lapse mid-drain.
  defp switch_action(state, inst, rule) do
    if Scheduler.can_sleep?(inst) do
      Webhook.pause(inst.id, :switching, Queue.hold_s())
      Relay.quiesce(inst.id)
      Logger.info("[queue] #{inst.name}: switching out (#{rule}); deliveries held")
      %{state | switch: %{since: System.monotonic_time(:millisecond), rule: rule, check_at: nil}}
    else
      state
    end
  end

  # One check per drain_check_ms on the controller's ticks, so a stop or a
  # delete that comes meanwhile is applied at once (rules 3 and 4).
  defp switch_step(state, inst) do
    now_ms = System.monotonic_time(:millisecond)
    sw = state.switch

    cond do
      # A failed status read is not a unit that died: keep draining (the cap
      # still bounds it) and read again next pass.
      state.unit == :unknown ->
        %{state | unit_at: nil}

      state.unit != :active ->
        finish_switch(state, inst, :down)

      now_ms - sw.since >= Queue.opt(:max_drain_s) * 1000 ->
        finish_switch(state, inst, :cap)

      sw.check_at && now_ms - sw.check_at < Queue.opt(:drain_check_ms) ->
        state

      drained?(inst) ->
        finish_switch(state, inst, :drained)

      true ->
        %{state | switch: %{sw | check_at: now_ms}}
    end
  end

  # Nothing delivered within the settle time (hermes buffers text up to 4 s
  # before a turn), no turn, hermes alone, no proxy call open.
  defp drained?(inst) do
    Idle.check(inst,
      window_s: Queue.opt(:settle_s),
      only: [:acked, :inflight, :turns, :processes]
    ) == :idle
  end

  defp finish_switch(state, inst, how) do
    sw = state.switch
    drained_s = div(System.monotonic_time(:millisecond) - sw.since, 1000)
    if how == :cap, do: cap_notice(inst)
    mem = Host.stats(inst.name)

    state =
      act(state, fn ->
        Host.stop(inst.name)
        set(inst, sleeping: true)
      end)

    Addressed.username(inst)
    warn_unreadable_jobs(state, inst)
    # Held rows stay stored and go to the bot on its next wake.
    Webhook.resume_if(inst.id, :switching)
    Relay.notify(inst.id)

    Logger.info(
      "[queue] #{inst.name}: switched out (#{sw.rule}, #{how}) after #{drained_s} s of drain#{rss(mem)}"
    )

    Scheduler.switch_done(inst.id)
    %{state | switch: nil}
  end

  # The one place a switch loses work, on purpose: the chat that spoke last
  # is told.
  defp cap_notice(inst) do
    Logger.warning(
      "[queue] #{inst.name}: still busy after #{div(Queue.opt(:max_drain_s), 60)} min of drain; stopping it"
    )

    with %Inbox{payload: payload} <- Inbox.last_delivered(inst.id),
         chat when not is_nil(chat) <- chat_id(payload),
         token when is_binary(token) and token != "" <- inst.telegram_token do
      Task.start(fn -> tell(inst, chat, @cap_text, "cap notice") end)
    end
  end

  @doc false
  # Best effort, logged either way: the person learns their work was dropped
  # or where they stand only if this lands.
  def tell(inst, chat, text, what) do
    case API.send_message(inst.telegram_token, chat, text) do
      {:ok, _} -> Logger.info("[queue] #{inst.name}: #{what} sent")
      other -> Logger.warning("[queue] #{inst.name}: #{what} failed: #{inspect(other)}")
    end
  rescue
    e -> Logger.warning("[queue] #{inst.name}: #{what} failed: #{Exception.message(e)}")
  end

  defp chat_id(payload) do
    case Jason.decode(payload) do
      {:ok, %{} = update} ->
        Enum.find_value(update, fn
          {_kind, %{"chat" => %{"id" => id}}} -> id
          {_kind, %{"message" => %{"chat" => %{"id" => id}}}} -> id
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  # A stop or a delete ends a switch: its hold is lifted and the stop rule
  # takes over with its own.
  defp abandon_switch(%{switch: nil} = state, _inst), do: state

  defp abandon_switch(state, inst) do
    Webhook.resume_if(inst.id, :switching)
    Logger.info("[queue] #{inst.name}: switch ended by a stop or delete")
    Scheduler.switch_done(inst.id)
    %{state | switch: nil}
  end

  # A new controller (after a crash or a druzhok restart) finds the hold of a
  # switch it did not start and carries on with it, its clock read from the
  # hold's end.
  defp carry_on_switch(
         %{switch: nil} = state,
         %Instance{
           active: true,
           sleeping: false,
           delete_requested: false
         } = inst
       ) do
    case Webhook.paused(inst) do
      {"switching", until} ->
        left_ms = DateTime.diff(until, DateTime.utc_now(), :millisecond)
        since = System.monotonic_time(:millisecond) - (Queue.hold_s() * 1000 - left_ms)
        Logger.info("[queue] #{inst.name}: carrying on a switch")
        %{state | switch: %{since: since, rule: :resumed, check_at: nil}}

      _ ->
        state
    end
  end

  defp carry_on_switch(state, _inst), do: state

  # Queue mode, on every sleep (idle or switched out): a job the file hides
  # runs late on the next wake.
  defp warn_unreadable_jobs(state, inst) do
    if state.queue and Idle.cron_wake_at(inst) == :error,
      do:
        Logger.warning(
          "[life] #{inst.name}: asleep with an unreadable jobs file; its jobs run on the next wake"
        )
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
      {held, _} when held not in ["stopping", "sleeping", "switching"] -> :ok
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
      cond do
        parked?(state, inst) ->
          state

        is_nil(state.unit_at) or
            System.monotonic_time(:millisecond) - state.unit_at >= opt(:unit_poll_ms) ->
          refresh(state, inst)

        true ->
          state
      end

    # Up by other means (druzhok-ctl by hand): nothing is waiting any more.
    if down?(state.unit), do: state, else: end_wait(state)
  end

  # Queue mode: an asleep or stopped (and acknowledged) bot whose unit was
  # last seen inactive does not read it every 30 s; at 200 rows those reads
  # are several `sudo` a second on one CPU. It reads again on a grant, a stop,
  # a delete, and when the scheduler's sweep finds its unit running. The
  # first read after the controller starts always happens.
  defp parked?(state, inst) do
    state.queue and state.unit == :inactive and not state.force_unit and not state.grant and
      not inst.delete_requested and
      ((inst.active and inst.sleeping) or (not inst.active and inst.stopped_seq >= inst.stop_seq))
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
  @doc false
  def backoff_over?(%Instance{start_failures: n}) when n in [nil, 0], do: true

  def backoff_over?(inst) do
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
