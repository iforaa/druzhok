defmodule Druzhok.Lifecycle.Bot do
  @moduledoc """
  One bot's lifecycle controller (sleep/wake spec, "Controller"). The only
  code that calls `Host.start/stop/destroy` for its bot or writes the
  controller columns of its row. It does one action at a time and, on every
  pass, applies the first rule that holds:

  1. row gone → exit
  2. unit stopping → wait
  3. `delete_requested` → stop, destroy, exit
  4. `!active` → stop, acknowledge the stop
  5. asleep → wake when there is a reason
  6. awake → recover a restart loop, start when down or asked, sleep when idle

  It keeps nothing that matters outside the row and the unit, so a new
  controller after a crash just applies the rules again.
  """

  use GenServer, restart: :transient
  require Logger
  alias Druzhok.{BotManager, Host, Instance, Repo}
  alias Druzhok.Lifecycle.{Idle, Typing}
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
    {:ok, %{id: id, unit: nil, unit_at: nil, activating_since: nil, idle_at: nil, timer: nil}}
  end

  @impl true
  def handle_info(:poke, state) do
    flush(:poke)
    pass(%{state | unit_at: nil})
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

    if down?(state.unit) do
      act(state, fn ->
        BotManager.destroy_instance(inst)
        Logger.info("[life] #{inst.name}: deleted")
      end)

      {:stop, state}
    else
      state
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
        Logger.info("[life] #{inst.name}: waking (#{describe(reason, inst)})")
        set(inst, sleeping: false, woke_at: now())
        if reason == :update, do: Typing.start(inst)
        start_action(state, inst)

      true ->
        state
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
        if backoff_over?(inst), do: start_action(state, inst), else: state

      state.unit == :active ->
        awake(state, inst)

      true ->
        state
    end
  end

  defp awake(state, inst) do
    if is_nil(inst.started_at), do: set(inst, started_at: now())

    if idle_check_due?(state) do
      state = %{state | idle_at: System.monotonic_time(:millisecond)}

      case Idle.check(inst) do
        :idle ->
          sleep_action(state, inst)

        {:busy, _} ->
          # A hold an interrupted action of ours left behind; the unit is up
          # and settled, so nothing is draining behind it.
          if inst.telegram_relay_pause_reason in ["stopping", "sleeping"],
            do: Webhook.resume_if(inst.id, inst.telegram_relay_pause_reason)

          state
      end
    else
      state
    end
  end

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
      not inst.sleep_enabled -> :sleep_disabled
      inst.telegram_mode != "webhook" or inst.telegram_mode != inst.started_mode -> :mode
      true -> nil
    end
  end

  # --- actions ----------------------------------------------------------------

  defp start_action(state, inst) do
    inst = Repo.get(Instance, inst.id)

    if runnable?(inst) do
      seq = inst.start_seq
      started = System.monotonic_time(:millisecond)
      set(inst, started_at: now(), started_mode: inst.telegram_mode)

      state =
        if state.unit in [:inactive, :unknown],
          do: state,
          else: act(state, fn -> stop_unit(inst, :stopping) end)

      # A stop that did not take (it raised, or the unit still drains) is
      # retried by the next pass; starting now would keep the old hermes.
      if down?(state.unit), do: run_start(state, inst, seq, started), else: state
    else
      state
    end
  end

  defp run_start(state, inst, seq, started) do
    {env, data_root} = BotManager.prepare_start(inst)
    latest = Repo.get(Instance, inst.id)

    # A Stop made during the drain or the file writes wins before Host.start.
    if runnable?(latest) do
      case Host.start(inst.name, env, data_root) do
        :ok ->
          case Host.status(inst.name) do
            :active -> started(state, inst, seq, started)
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

  defp started(state, inst, seq, t0) do
    set(inst, applied_seq: seq, start_error: nil, start_failed_at: nil, start_failures: 0)
    # A restart is how a rejected_config pause gets fixed; a foreign process
    # on the port is not.
    Webhook.resume_except(inst.id, :wrong_owner)
    Relay.notify(inst.id)

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
    if is_nil(state.unit_at) or
         System.monotonic_time(:millisecond) - state.unit_at >= opt(:unit_poll_ms),
       do: refresh(state, inst),
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

  @doc "When a bot that failed to start is tried again (nil when it is not failing)."
  def next_attempt(%Instance{start_failures: n, start_failed_at: %DateTime{} = at})
      when is_integer(n) and n > 0,
      do: DateTime.add(at, backoff_ms(n), :millisecond)

  def next_attempt(_), do: nil

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
    activating_limit_ms: 330_000,
    backoff_ms: [10_000, 60_000, 300_000, 900_000]
  ]

  defp opt(key),
    do: Keyword.get(Application.get_env(:druzhok, :lifecycle, []), key, @defaults[key])
end
