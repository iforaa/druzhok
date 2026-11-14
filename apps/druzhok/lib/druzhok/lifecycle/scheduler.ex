defmodule Druzhok.Lifecycle.Scheduler do
  @moduledoc """
  Queue mode's one line (bot queue spec, "The line and admission" and
  "Switch"). Does nothing while `bot_slots` is unset.

  A bot holds a slot while its row is active, not being deleted and not
  sleeping. Every tick (2 s, or a poke) the scheduler reads the rows and:

  1. builds the line from live data, never stored: sleeping bots whose
     backoff is over and that have a `Lifecycle.Wake` reason, oldest first
     (an update by its oldest waking row's `received_at`, a reminder by its
     wake time, anything else by when this scheduler first saw it waiting);
  2. tells a private chat that has waited a minute where it stands, once per
     wait;
  3. while fewer than `bot_slots` hold a slot, counting database holders and
     live `hermes@*` units together by name, grants the head one attempt:
     its controller takes the one-start lock, counts again inside it, and only
     then wakes (`Lifecycle.Bot`). No new grant goes out until that one is
     used or dropped;
  4. while the line waits and every slot is held, asks one awake bot to make
     room: a quiet one after the 60 s grace, else the longest holder once its
     slice is over (3 more minutes while its user is chatting). The controller
     holds deliveries, drains and stops it (`switch_action`);
  5. once a minute, one unit listing points controllers whose row is asleep
     or stopped at a unit that runs (a start by hand), since in queue mode
     those controllers no longer read their unit every 30 s.

  It keeps only what may be lost: grants and switches in flight (monitored),
  when it first saw each waiting bot, the notices sent, cached jobs files.
  """

  use GenServer
  require Logger
  import Ecto.Query
  alias Druzhok.{Host, Instance, Lifecycle, Repo}
  alias Druzhok.Lifecycle.{Bot, Idle, Queue, Typing, Wake}
  alias Druzhok.Telegram.{Inbox, Webhook}

  @grace_checks [:telegram, :acked, :proxy, :inflight, :turns, :cron_lead, :processes]
  # A cached jobs file is read again at least this often, whatever its mtime says.
  @cron_reread_ms 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Look at the line now. No-op where the scheduler does not run."
  def poke, do: tell_self(:poke)

  @doc """
  The line as last computed: `[{bot name, wake reason}]`, head first. Exits
  when the scheduler does not answer within `timeout` ms.
  """
  def line(timeout \\ 5_000), do: GenServer.call(__MODULE__, :line, timeout)

  @doc false
  # `used?`: the bot woke. A dropped grant is tried again on the next tick,
  # not at once, or a lock held for minutes would spin the two processes.
  def grant_done(id, used?), do: tell_self({:grant_done, id, used?})

  @doc false
  def switch_done(id), do: tell_self({:switch_done, id})

  defp tell_self(msg) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, msg)
    end

    :ok
  end

  @doc """
  Whether one more bot may start: holders (database and live units, by name)
  below `bot_slots`. True outside queue mode; false when the units cannot be
  listed. A controller asks this inside the one-start lock.
  """
  def room? do
    case Queue.slots() do
      nil ->
        true

      n ->
        names = scope() |> rows_query() |> where([i], not i.sleeping) |> select([i], i.name)

        case union(Repo.all(names)) do
          {:ok, set} -> MapSet.size(set) < n
          :error -> false
        end
    end
  end

  defp union(db_names) do
    with {:ok, units} <- Host.holding_units() do
      {:ok, MapSet.union(MapSet.new(db_names), MapSet.new(Map.keys(units)))}
    end
  end

  # `Lifecycle` with `scan: false` (tests) looks after poked bots only, so the
  # scheduler counts only rows that have a controller, never the other rows of
  # a shared database.
  defp scope, do: :persistent_term.get({__MODULE__, :scope}, :all)

  defp rows_query(scope) do
    q = from(i in Instance, where: i.active and not i.delete_requested)

    case scope do
      :all -> q
      :controlled -> where(q, [i], i.id in ^controlled_ids())
    end
  end

  defp controlled_ids,
    do: Registry.select(Druzhok.Registry, [{{{:lifecycle, :"$1"}, :_, :_}, [], [:"$1"]}])

  # --- server ---------------------------------------------------------------

  @impl true
  def init(opts) do
    scope = Keyword.get(opts, :scope, :all)

    if :persistent_term.get({__MODULE__, :scope}, nil) != scope,
      do: :persistent_term.put({__MODULE__, :scope}, scope)

    send(self(), :tick)

    {:ok,
     %{
       scope: scope,
       on: false,
       first_seen: %{},
       notified: %{},
       cron: %{},
       grant: nil,
       switch: nil,
       sweep_at: nil,
       switch_at: nil,
       summary: nil,
       warned: false,
       line: [],
       timer: nil
     }}
  end

  @impl true
  def handle_call(:line, _from, state), do: {:reply, state.line, state}

  @impl true
  def handle_info(:tick, state), do: {:noreply, state |> run() |> schedule()}

  def handle_info(:poke, state) do
    flush(:poke)
    {:noreply, state |> run() |> schedule()}
  end

  def handle_info({:grant_done, id, used?}, %{grant: %{id: id, ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    if used?, do: send(self(), :poke)
    {:noreply, %{state | grant: nil}}
  end

  def handle_info({:switch_done, id}, %{switch: %{id: id, ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    send(self(), :poke)
    {:noreply, %{state | switch: nil}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    state =
      case state do
        %{grant: %{ref: ^ref}} -> %{state | grant: nil}
        %{switch: %{ref: ^ref}} -> %{state | switch: nil}
        _ -> state
      end

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp flush(msg) do
    receive do
      ^msg -> flush(msg)
    after
      0 -> :ok
    end
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :tick, Queue.opt(:queue_tick_ms))}
  end

  # A bug here must not take the lifecycle supervisor down with it: the
  # controllers keep running, and the next tick tries again.
  defp run(state) do
    case Queue.slots() do
      nil ->
        if state.on, do: Logger.info("[queue] off: bot_slots unset")
        %{state | on: false, first_seen: %{}, notified: %{}, cron: %{}, summary: nil, line: []}

      n ->
        if not state.on, do: Logger.info("[queue] on: #{n} slots")
        step(%{state | on: true}, n)
    end
  rescue
    e ->
      Logger.error("[queue] #{Exception.format(:error, e, __STACKTRACE__)}")
      state
  end

  defp step(state, n) do
    now = DateTime.utc_now()
    rows = Repo.all(rows_query(state.scope))
    {sleeping, holders} = Enum.split_with(rows, & &1.sleeping)
    {line, state} = line(state, sleeping, now)

    state
    |> sweep()
    |> notices(line, rows, now)
    |> admit(n, holders, line)
    |> switch(n, holders, line, now)
    |> report(n, holders, line, now)
  end

  # --- the line -------------------------------------------------------------

  defp line(state, sleeping, now) do
    waking = Inbox.oldest_waking(now)

    {entries, cron} =
      Enum.flat_map_reduce(sleeping, %{}, fn inst, cache ->
        {result, entry} = cron_for(inst, state.cron)
        cache = Map.put(cache, inst.id, entry)

        reason =
          Bot.backoff_over?(inst) &&
            Wake.reason(inst, queue: true, waking_at: waking[inst.id], cron: result)

        if reason, do: {[{inst, reason, result}], cache}, else: {[], cache}
      end)

    first_seen =
      Map.new(entries, fn {inst, _, _} -> {inst.id, Map.get(state.first_seen, inst.id, now)} end)

    line =
      entries
      |> Enum.map(fn {inst, reason, cron} ->
        %{inst: inst, reason: reason, key: key(reason, inst, waking, cron, first_seen)}
      end)
      |> Enum.sort_by(&{DateTime.to_unix(&1.key, :microsecond), &1.inst.id})

    names = Enum.map(line, &{&1.inst.name, &1.reason})
    {line, %{state | first_seen: first_seen, cron: cron, line: names}}
  end

  defp key(:update, inst, waking, _cron, _seen), do: waking[inst.id]
  defp key(:cron, _inst, _waking, {:ok, %DateTime{} = at}, _seen), do: at
  defp key(_reason, inst, _waking, _cron, seen), do: seen[inst.id]

  # A jobs file is read again only when it changed, or a minute has passed
  # (mtime has whole seconds).
  defp cron_for(inst, cache) do
    stamp =
      case File.stat(Idle.cron_path(inst), time: :posix) do
        {:ok, %{mtime: m, size: s}} -> {m, s}
        {:error, :enoent} -> :none
        _ -> :unreadable
      end

    now_ms = System.monotonic_time(:millisecond)

    case cache[inst.id] do
      {^stamp, result, at} when stamp != :unreadable and now_ms - at < @cron_reread_ms ->
        {result, {stamp, result, at}}

      _ ->
        result = Idle.cron_wake_at(inst)
        {result, {stamp, result, now_ms}}
    end
  end

  # --- notices --------------------------------------------------------------

  @doc false
  def notice_text(0), do: "Бот просыпается, ответ скоро придёт."

  def notice_text(ahead),
    do:
      "Бот сейчас отвечает другим. Перед вами в очереди: #{ahead}. " <>
        "Ответ придёт сам, писать ещё раз не нужно."

  # Once per wait: the wait is named by its oldest waking row's received_at,
  # remembered while the bot is active, so a wake that did not get to the row
  # does not tell the chat again.
  defp notices(state, line, rows, now) do
    active = MapSet.new(rows, & &1.id)
    notified = Map.filter(state.notified, fn {id, _} -> MapSet.member?(active, id) end)
    after_s = Queue.opt(:notice_after_s)

    notified =
      line
      |> Enum.with_index()
      |> Enum.reduce(notified, fn
        {%{reason: :update, inst: inst, key: key}, place}, acc ->
          if acc[inst.id] != key and DateTime.diff(now, key) >= after_s do
            send_notice(inst, place)
            Map.put(acc, inst.id, key)
          else
            acc
          end

        _, acc ->
          acc
      end)

    %{state | notified: notified}
  end

  defp send_notice(inst, ahead) do
    with %Inbox{payload: payload} <- Inbox.next_waking(inst.id),
         chat when not is_nil(chat) <- Typing.chat_id(payload),
         true <- inst.telegram_token not in [nil, ""] do
      what = "line notice (#{ahead} ahead)"
      Task.start(fn -> Bot.tell(inst, chat, notice_text(ahead), what) end)
    end
  end

  # --- admission ------------------------------------------------------------

  defp admit(state, n, holders, line) do
    cond do
      state.grant != nil or line == [] or length(holders) >= n ->
        state

      true ->
        case union(Enum.map(holders, & &1.name)) do
          {:ok, set} ->
            if MapSet.size(set) < n, do: grant(state, hd(line)), else: state

          :error ->
            Logger.warning("[queue] cannot list hermes units; nothing admitted")
            state
        end
    end
  end

  defp grant(state, %{inst: inst, reason: reason, key: key}) do
    case Lifecycle.ensure(inst.id) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        send(pid, :grant)

        Logger.info(
          "[queue] #{inst.name}: granted (#{reason}, waited #{wait(DateTime.diff(DateTime.utc_now(), key))})"
        )

        %{state | grant: %{id: inst.id, ref: ref}}

      _ ->
        state
    end
  end

  # --- switch ---------------------------------------------------------------

  defp switch(state, n, holders, line, now) do
    cond do
      line == [] or state.grant != nil or state.switch != nil or length(holders) < n ->
        state

      Enum.any?(holders, &match?({"switching", _}, Webhook.paused(&1))) ->
        state

      not due?(state.switch_at, Queue.opt(:switch_check_ms)) ->
        state

      true ->
        state = %{state | switch_at: System.monotonic_time(:millisecond)}

        case pick(holders, now) do
          nil -> state
          {inst, rule} -> ask_switch(state, inst, rule, now)
        end
    end
  end

  defp pick(holders, now) do
    movable =
      holders
      |> Enum.filter(&can_sleep?/1)
      |> Enum.sort_by(&{unix(&1.woke_at), &1.id})

    grace = Queue.opt(:grace_s)

    quiet =
      Enum.find(movable, fn inst ->
        awake_s(inst, now) >= grace and
          Idle.check(inst, window_s: grace, queue: true, only: @grace_checks) == :idle
      end)

    oldest = List.first(movable)

    cond do
      quiet -> {quiet, :grace}
      oldest && turn_over?(oldest, now, grace) -> {oldest, :turn}
      true -> nil
    end
  end

  # The one extension: a user chatting (a delivery within the grace) gets 3
  # more minutes, after which the slice ends anyway. A reminder due soon is no
  # exemption: it runs on the next wake.
  defp turn_over?(inst, now, grace) do
    held = held_s(inst, now)
    slice = Queue.slice_s()

    held >= slice and
      (held >= slice + Queue.opt(:extension_s) or
         Idle.check(inst, window_s: grace, only: [:acked]) == :idle)
  end

  defp ask_switch(state, inst, rule, now) do
    case Lifecycle.ensure(inst.id) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        send(pid, {:switch, rule})

        Logger.info(
          "[queue] #{inst.name}: switch asked (#{rule}, held #{wait(held_s(inst, now))})"
        )

        %{state | switch: %{id: inst.id, ref: ref}}

      _ ->
        state
    end
  end

  @doc "Whether a switch may stop the bot: bots that cannot sleep keep their slot."
  def can_sleep?(inst),
    do: inst.sleep_enabled and inst.telegram_mode == "webhook" and inst.started_mode == "webhook"

  # Since its last wake: a restart in place keeps the slot and the clock.
  defp held_s(inst, now), do: DateTime.to_unix(now) - unix(inst.woke_at)

  # Since it last came up, a restart included.
  defp awake_s(inst, now),
    do: DateTime.to_unix(now) - max(unix(inst.woke_at), unix(inst.started_at))

  defp unix(%DateTime{} = at), do: DateTime.to_unix(at)
  defp unix(_), do: 0

  # --- sweep ----------------------------------------------------------------

  defp sweep(state) do
    if due?(state.sweep_at, Queue.opt(:sweep_ms)) do
      case Host.holding_units() do
        {:ok, units} ->
          running = for {name, s} <- units, s in [:active, :activating, :reloading], do: name
          if running != [], do: point_at_running(state.scope, running)

        :error ->
          Logger.warning("[queue] sweep: cannot list hermes units")
      end

      %{state | sweep_at: System.monotonic_time(:millisecond)}
    else
      state
    end
  end

  defp point_at_running(scope, names) do
    base =
      case scope do
        :all -> from(i in Instance)
        :controlled -> from(i in Instance, where: i.id in ^controlled_ids())
      end

    from(i in base,
      where: i.name in ^names and (i.sleeping or not i.active) and not i.delete_requested,
      select: i.id
    )
    |> Repo.all()
    |> Enum.each(fn id ->
      with {:ok, pid} <- Lifecycle.ensure(id), do: send(pid, :unit_running)
    end)
  end

  # --- logging --------------------------------------------------------------

  defp report(state, n, holders, line, now) do
    cant = Enum.count(holders, &(not can_sleep?(&1)))

    oldest_s =
      case line do
        [] -> 0
        [%{key: key} | _] -> max(DateTime.diff(now, key), 0)
      end

    summary = {length(line), length(holders), cant}

    if summary != state.summary do
      cant_text = if cant > 0, do: " (#{cant} by bots that cannot sleep)", else: ""

      Logger.info(
        "[queue] line #{length(line)} (oldest wait #{wait(oldest_s)}), " <>
          "slots #{length(holders)}/#{n}#{cant_text}"
      )
    end

    warn_s = Queue.opt(:oldest_warn_s)

    warned =
      cond do
        oldest_s >= warn_s and not state.warned ->
          Logger.warning(
            "[queue] the oldest wait is #{wait(oldest_s)}; held updates expire at 24 h"
          )

          true

        oldest_s < warn_s ->
          false

        true ->
          state.warned
      end

    %{state | summary: summary, warned: warned}
  end

  defp wait(s) when s < 120, do: "#{s} s"
  defp wait(s), do: "#{div(s, 60)} min"

  defp due?(nil, _ms), do: true
  defp due?(at, ms), do: System.monotonic_time(:millisecond) - at >= ms
end
