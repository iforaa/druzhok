defmodule Druzhok.LifecycleQueueTest do
  @moduledoc "Queue mode: slots, the line, admission and the switch (bot queue spec)."
  # async: false — app env (host, lifecycle timings), a named supervisor, the
  # global start lock.
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  import Ecto.Query, only: [from: 2]
  alias Druzhok.{BotManager, HostStub, Inflight, Instance, Lifecycle, Repo}
  alias Druzhok.Lifecycle.{Scheduler, StartGate}
  alias Druzhok.Telegram.{Inbox, Webhook}

  # Bots stay awake unless a test wants otherwise, the sweep and turn-over
  # are off, and checks run on every tick.
  @queue [
    idle_window_s: 3600,
    bot_slots: 1,
    queue_tick_ms: 30,
    switch_check_ms: 0,
    drain_check_ms: 0,
    sweep_ms: 3_600_000,
    slice_s: 3600
  ]

  setup do
    %{data_root: root} = with_tmp_data_root()
    HostStub.use()

    prev = Application.get_env(:druzhok, :lifecycle)
    Application.put_env(:druzhok, :lifecycle, Keyword.merge(prev, @queue))
    on_exit(fn -> Application.put_env(:druzhok, :lifecycle, prev) end)

    start_lifecycle()
    %{root: root}
  end

  defp env(kw),
    do:
      Application.put_env(
        :druzhok,
        :lifecycle,
        Keyword.merge(Application.get_env(:druzhok, :lifecycle), kw)
      )

  defp ago(s), do: DateTime.utc_now() |> DateTime.add(-s) |> DateTime.truncate(:second)

  # An awake webhook bot that may sleep, up and idle for 10 min.
  defp bot(root, attrs \\ %{}) do
    id = 100 + rem(System.unique_integer([:positive]), 899)
    name = "q#{id}"

    inst =
      relay_instance(
        Map.merge(
          %{
            id: id,
            name: name,
            workspace: Path.join([root, name, "workspace"]),
            telegram_mode: "webhook",
            telegram_webhook_secret: "s",
            telegram_token: "T#{id}",
            sleep_enabled: true,
            started_mode: "webhook",
            started_at: ago(600),
            woke_at: ago(600),
            active: true
          },
          attrs
        )
      )

    turns(inst, 0)

    unit =
      Map.get(attrs, :unit, if(inst.sleeping or not inst.active, do: :inactive, else: :active))

    HostStub.set_unit(name, unit)
    inst
  end

  defp asleep(root, attrs \\ %{}), do: bot(root, Map.merge(%{sleeping: true}, attrs))

  # Holds a slot for good: it cannot sleep, so no switch picks it.
  defp blocker(root), do: bot(root, %{sleep_enabled: false})

  defp turns(inst, n) do
    dir = Path.dirname(inst.workspace)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "gateway_state.json"),
      Jason.encode!(%{"gateway_state" => "running", "active_agents" => n})
    )
  end

  defp cron_file(inst, body) do
    dir = Path.join(Path.dirname(inst.workspace), "cron")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "jobs.json"), body)
  end

  defp job_at(inst, s) do
    at = DateTime.utc_now() |> DateTime.add(s) |> DateTime.to_iso8601()
    cron_file(inst, ~s({"jobs":[{"id":"a","next_run_at":"#{at}"}]}))
  end

  # A private message from chat 5000 + id, received `ago` seconds back.
  defp msg(inst, update_id, opts \\ []) do
    chat = Keyword.get(opts, :chat, 5000 + inst.id)

    payload =
      Jason.encode!(%{
        update_id: update_id,
        message: %{message_id: 1, chat: %{id: chat, type: "private"}, text: "hi"}
      })

    :ok = Inbox.enqueue(inst.id, update_id, payload)
    at = DateTime.add(DateTime.utc_now(), -Keyword.get(opts, :ago, 0))

    from(u in Inbox, where: u.instance_id == ^inst.id and u.update_id == ^update_id)
    |> Repo.update_all(set: [received_at: at])

    if acked = opts[:acked] do
      from(u in Inbox, where: u.instance_id == ^inst.id and u.update_id == ^update_id)
      |> Repo.update_all(set: [acked_at: DateTime.add(DateTime.utc_now(), -acked)])
    end

    :ok
  end

  defp reload(inst), do: Repo.get!(Instance, inst.id)
  defp poke(insts) when is_list(insts), do: Enum.each(insts, &poke/1)
  defp poke(inst), do: Lifecycle.poke(inst.id)

  defp set(inst, changes),
    do: Repo.update_all(from(i in Instance, where: i.id == ^inst.id), set: changes)

  defp starts, do: HostStub.calls(:start)
  defp started?(inst), do: inst.name in starts()
  defp stopped?(inst), do: inst.name in HostStub.calls(:stop)
  defp switching?(inst), do: match?({"switching", _}, Webhook.paused(reload(inst)))

  defp status_reads(inst), do: Enum.count(HostStub.calls(:status), &(&1 == inst.name))

  # The most bots that ever held a slot at once, database and units by name,
  # sampled every few ms for the rest of the test.
  # `units: true` counts live units only: rows a reboot left awake hold a slot
  # in the database until their controller marks them asleep.
  defp watch(insts, opts \\ []) do
    ids = if opts[:units], do: [], else: Enum.map(insts, & &1.id)
    names = Enum.map(insts, & &1.name)
    {:ok, agent} = Agent.start(fn -> 0 end)
    pid = spawn(fn -> sample(agent, ids, names) end)

    on_exit(fn ->
      Process.exit(pid, :kill)
      if Process.alive?(agent), do: Agent.stop(agent)
    end)

    agent
  end

  defp sample(agent, ids, names) do
    db =
      from(i in Instance,
        where: i.id in ^ids and i.active and not i.sleeping and not i.delete_requested,
        select: i.name
      )
      |> Repo.all()

    live =
      for {name, unit} <- HostStub.units(),
          name in names,
          unit in [:active, :activating, :restarting, :stopping],
          do: name

    n = MapSet.size(MapSet.union(MapSet.new(db), MapSet.new(live)))
    Agent.update(agent, &max(&1, n))
    Process.sleep(3)
    sample(agent, ids, names)
  end

  defp most(agent), do: Agent.get(agent, & &1)

  # A Telegram API stub that forwards every call to the test process.
  defp telegram do
    bypass = Bypass.open()
    test = self()
    prev = Application.get_env(:druzhok, :telegram_api_base)
    Application.put_env(:druzhok, :telegram_api_base, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      if prev,
        do: Application.put_env(:druzhok, :telegram_api_base, prev),
        else: Application.delete_env(:druzhok, :telegram_api_base)
    end)

    Bypass.expect(bypass, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:telegram, conn.request_path, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"ok":true,"result":{"message_id":1}}))
    end)

    bypass
  end

  defp sent_texts(inst) do
    path = "/botT#{inst.id}/sendMessage"
    collect(path, [])
  end

  defp collect(path, acc) do
    receive do
      {:telegram, ^path, %{"text" => text, "chat_id" => chat}} ->
        collect(path, [{chat, text} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "queue mode off" do
    test "with bot_slots unset an update wakes the bot by itself and the scheduler does nothing",
         %{root: root} do
      env(bot_slots: nil)
      # The scheduler's first tick may have come before the change.
      Process.sleep(100)
      listed = length(HostStub.calls(:holding_units))
      a = asleep(root)
      msg(a, 1)
      poke(a)

      assert eventually(fn -> starts() == [a.name] end)
      refute reload(a).sleeping
      Process.sleep(100)
      assert length(HostStub.calls(:holding_units)) == listed
      assert Scheduler.line() == []
    end
  end

  describe "slots" do
    test "a new or stopped bot started in queue mode waits in the line", %{root: root} do
      b = blocker(root)
      s = bot(root, %{active: false})
      poke(b)

      assert {:ok, _} = BotManager.start(s.name)
      row = reload(s)
      assert row.active and row.sleeping
      assert eventually(fn -> Scheduler.line() == [{s.name, :requested}] end)
      Process.sleep(150)
      refute started?(s)

      assert :ok = BotManager.stop(b.name, wait: true)
      assert eventually(fn -> started?(s) end)
      refute reload(s).sleeping
    end

    test "a burst of new bots never takes more than N slots", %{root: root} do
      env(bot_slots: 2)
      bots = for _ <- 1..5, do: bot(root, %{active: false})
      top = watch(bots)

      Enum.each(bots, &BotManager.start(&1.name))
      assert eventually(fn -> length(starts()) == 2 end)
      Process.sleep(300)
      assert length(starts()) == 2
      assert most(top) <= 2
      assert Enum.count(bots, &reload(&1).sleeping) == 3
    end

    test "after a druzhok restart the bots found down go back through the line", %{root: root} do
      # Rows awake, units down: what a reboot leaves.
      a = bot(root, %{unit: :inactive})
      b = bot(root, %{unit: :inactive})
      msg(a, 1)
      msg(b, 1)
      top = watch([a, b], units: true)
      poke([a, b])

      assert eventually(fn -> length(starts()) == 1 end)
      Process.sleep(300)
      assert length(starts()) == 1
      assert most(top) <= 1
    end

    test "a settings restart keeps its slot: nobody is admitted while it runs", %{root: root} do
      a = bot(root, %{settings_seq: 1, settings_applied_seq: 0})
      b = asleep(root)
      msg(b, 1, ago: 30)
      top = watch([a, b])
      HostStub.hook(:start, fn _ -> Process.sleep(300) end)
      poke(a)
      poke(b)

      assert eventually(fn -> started?(a) end)
      assert hd(starts()) == a.name
      Process.sleep(300)
      assert most(top) <= 1
    end

    test "nothing is admitted while the units cannot be listed", %{root: root} do
      HostStub.set_list(:error)
      a = asleep(root)
      msg(a, 1)
      poke(a)

      Process.sleep(300)
      refute started?(a)

      HostStub.set_list(:ok)
      assert eventually(fn -> started?(a) end)
    end

    test "a unit still stopping holds its slot until it is down", %{root: root} do
      x = bot(root, %{active: false, unit: :stopping})
      a = asleep(root)
      msg(a, 1)
      poke(a)

      Process.sleep(300)
      refute started?(a)

      HostStub.set_unit(x.name, :inactive)
      assert eventually(fn -> started?(a) end)
    end

    test "the union: a bot mid-restart and a bot still stopping count as two", %{root: root} do
      env(bot_slots: 2)
      a = bot(root, %{sleep_enabled: false})
      x = bot(root, %{active: false, unit: :stopping})
      c = asleep(root)
      msg(c, 1)
      poke([a, c])

      # During a's restart its unit is down: only the row says it holds a slot.
      HostStub.hook(:start, fn _ -> Process.sleep(400) end)
      BotManager.restart(a.name)
      assert eventually(fn -> started?(a) end)
      Process.sleep(200)
      refute started?(c)

      HostStub.set_unit(x.name, :inactive)
      assert eventually(fn -> started?(c) end)
    end

    test "a failed start frees its slot, waits out its backoff, then comes back", %{root: root} do
      a = asleep(root)
      b = asleep(root)
      msg(a, 1, ago: 60)
      msg(b, 1, ago: 30)
      HostStub.on_start(a.name, {:error, :boom})
      poke([a, b])

      # Recorded, stopped, then back to sleep: the slot is free.
      assert eventually(fn -> reload(a).start_failures == 1 and reload(a).sleeping end)
      assert HostStub.status(a.name) == :inactive
      # Its slot went to b at once; a is not in the line during its backoff.
      assert eventually(fn -> started?(b) end)
      refute Enum.any?(Scheduler.line(), fn {name, _} -> name == a.name end)

      HostStub.on_start(a.name, :ok)
      assert eventually(fn -> Enum.any?(Scheduler.line(), fn {name, _} -> name == a.name end) end)
      assert :ok = BotManager.stop(b.name, wait: true)
      assert eventually(fn -> HostStub.status(a.name) == :active end)
      assert reload(a).start_failures == 0
    end

    test "a hand-started unit is marked awake by the sweep", %{root: root} do
      env(bot_slots: 2)
      a = asleep(root)
      poke(a)
      assert eventually(fn -> status_reads(a) == 1 end)

      HostStub.set_unit(a.name, :active)
      Process.sleep(200)
      assert reload(a).sleeping

      env(sweep_ms: 50)
      assert eventually(fn -> not reload(a).sleeping end)
      assert starts() == []
    end

    test "an asleep bot reads its unit once, then not on pokes or ticks", %{root: root} do
      env(bot_slots: 2)
      a = asleep(root)
      poke(a)
      assert eventually(fn -> status_reads(a) == 1 end)

      for _ <- 1..5, do: poke(a)
      Process.sleep(300)
      assert status_reads(a) == 1
    end

    test "low memory does not refuse a start in queue mode: only the lock is kept",
         %{root: root} do
      meminfo = Path.join(root, "meminfo")
      File.write!(meminfo, "MemTotal: 4000000 kB\nMemAvailable:  102400 kB\n")
      env(meminfo_path: meminfo, start_min_free_mb: 900)
      a = asleep(root)
      msg(a, 1)
      poke(a)
      assert eventually(fn -> started?(a) end)
    end
  end

  describe "the line" do
    test "oldest message or due job first, then by when first seen", %{root: root} do
      b0 = blocker(root)
      a = asleep(root)
      b = asleep(root)
      c = asleep(root)
      d = asleep(root)
      msg(b, 1, ago: 300)
      msg(a, 1, ago: 200)
      msg(c, 1, ago: 100)
      # Due 70 s ago: its wake time, 3 min before that, is 250 s back.
      job_at(d, -70)
      e = bot(root, %{active: false})
      f = bot(root, %{active: false})
      poke([b0, a, b, c, d])

      BotManager.start(e.name)
      assert eventually(fn -> Enum.any?(Scheduler.line(), &(elem(&1, 0) == e.name)) end)
      Process.sleep(20)
      BotManager.start(f.name)

      assert eventually(fn ->
               Scheduler.line() == [
                 {b.name, :update},
                 {d.name, :cron},
                 {a.name, :update},
                 {c.name, :update},
                 {e.name, :requested},
                 {f.name, :requested}
               ]
             end)

      # The slot frees: the head goes first.
      BotManager.stop(b0.name, wait: true)
      assert eventually(fn -> starts() == [b.name] end)
    end

    test "a switched-out bot goes behind older messages", %{root: root} do
      env(slice_s: 0)
      a = bot(root)
      b = asleep(root)
      # a has a message it has not had yet, newer than b's.
      msg(a, 1, ago: 5)
      msg(b, 1, ago: 120)
      poke([a, b])

      assert eventually(fn -> reload(a).sleeping end)
      assert eventually(fn -> starts() != [] end)
      assert hd(starts()) == b.name
    end

    test "a candidate whose rows were dropped leaves the line and does not block it",
         %{root: root} do
      b0 = blocker(root)
      a = asleep(root)
      b = asleep(root)
      msg(a, 1, ago: 200)
      msg(b, 1, ago: 100)
      poke([b0, a, b])
      assert eventually(fn -> Scheduler.line() == [{a.name, :update}, {b.name, :update}] end)

      Inbox.drop_pending(a.id, "expired")
      assert eventually(fn -> Scheduler.line() == [{b.name, :update}] end)

      BotManager.stop(b0.name, wait: true)
      assert eventually(fn -> started?(b) end)
      refute started?(a)
    end

    test "an unreadable jobs file neither wakes a bot nor keeps one awake", %{root: root} do
      env(bot_slots: 2, idle_window_s: 60)
      a = asleep(root)
      cron_file(a, "not json")
      b = bot(root)
      cron_file(b, "not json")
      poke([a, b])

      assert eventually(fn -> reload(b).sleeping end)
      Process.sleep(200)
      refute started?(a)
      assert Scheduler.line() == []
    end

    test "grants refused at the lock are dropped; after it frees only N get in", %{root: root} do
      a = asleep(root)
      b = asleep(root)
      msg(a, 1, ago: 60)
      msg(b, 1, ago: 30)
      top = watch([a, b])
      test = self()

      holder =
        spawn(fn ->
          :global.trans(
            {StartGate, self()},
            fn ->
              send(test, :locked)

              receive do
                :release -> :ok
              end
            end,
            [node()],
            0
          )
        end)

      assert_receive :locked
      poke([a, b])
      Process.sleep(300)
      assert starts() == []

      send(holder, :release)
      assert eventually(fn -> starts() == [a.name] end)
      Process.sleep(300)
      assert starts() == [a.name]
      assert most(top) <= 1
    end
  end

  describe "the switch" do
    test "grace comes before turn-over, and takes the longest of the quiet bots", %{root: root} do
      # a's slice is over too, so turn-over alone would pick a.
      env(bot_slots: 3, slice_s: 300)
      a = bot(root, %{woke_at: ago(1000)})
      turns(a, 1)
      b = bot(root, %{woke_at: ago(600)})
      d = bot(root, %{woke_at: ago(700)})
      c = asleep(root)
      msg(c, 1)
      poke([a, b, d, c])

      assert eventually(fn -> reload(d).sleeping end)
      refute stopped?(a)
      refute stopped?(b)
      assert eventually(fn -> started?(c) end)
    end

    test "with nothing delivered lately, turn-over comes at the plain slice", %{root: root} do
      env(slice_s: 300, extension_s: 180)
      a = bot(root, %{woke_at: ago(350)})
      turns(a, 1)
      b = asleep(root)
      msg(b, 1)
      poke([a, b])

      assert eventually(fn -> switching?(a) end)
    end

    test "a failed status read neither ends a drain nor gives up a slot", %{root: root} do
      env(slice_s: 0)
      HostStub.set_procs(2)
      a = bot(root)
      b = asleep(root)
      msg(b, 1)
      poke([a, b])
      assert eventually(fn -> switching?(a) end)

      HostStub.set_unit(a.name, :unknown)
      Process.sleep(300)
      refute stopped?(a)
      refute reload(a).sleeping
      assert switching?(a)
      refute started?(b)

      HostStub.set_unit(a.name, :active)
      HostStub.set_procs(1)
      assert eventually(fn -> reload(a).sleeping end)
      assert eventually(fn -> started?(b) end)
    end

    test "an awake bot whose status read fails keeps its slot and is not started", %{root: root} do
      a = bot(root, %{unit: :unknown})
      b = asleep(root)
      msg(b, 1)
      poke([a, b])

      Process.sleep(300)
      refute reload(a).sleeping
      assert starts() == []
    end

    test "turn-over picks the longest holder once its slice is over", %{root: root} do
      env(bot_slots: 2, slice_s: 300)
      a = bot(root, %{woke_at: ago(1000)})
      b = bot(root, %{woke_at: ago(600)})
      turns(a, 1)
      turns(b, 1)
      c = asleep(root)
      msg(c, 1)
      poke([a, b, c])

      assert eventually(fn -> switching?(a) end)
      refute switching?(b)
      # The drain waits for the turn to end.
      Process.sleep(150)
      refute stopped?(a)
      turns(a, 0)
      assert eventually(fn -> reload(a).sleeping end)
      refute stopped?(b)
    end

    test "a user chatting gets one 3-minute extension, then the slice ends anyway",
         %{root: root} do
      env(slice_s: 300, extension_s: 180)
      a = bot(root, %{woke_at: ago(400)})
      turns(a, 1)
      msg(a, 1, ago: 12, acked: 10)
      b = asleep(root)
      msg(b, 1)
      poke([a, b])

      Process.sleep(300)
      refute switching?(a)

      set(a, woke_at: ago(500))
      assert eventually(fn -> switching?(a) end)
    end

    test "a bot with a job every few minutes still takes its turn", %{root: root} do
      env(slice_s: 300)
      a = bot(root)
      job_at(a, 60)
      b = asleep(root)
      # Waiting longer than a's job (due in 1 min, so in the line from 2 min ago).
      msg(b, 1, ago: 300)
      poke([a, b])

      assert eventually(fn -> stopped?(a) end)
      assert eventually(fn -> started?(b) end)
      assert starts() == [b.name]
    end

    test "bots that cannot sleep are never switched", %{root: root} do
      env(slice_s: 0)
      a = blocker(root)
      p = bot(root, %{telegram_mode: "polling", started_mode: "polling"})
      env(bot_slots: 2)
      b = asleep(root)
      msg(b, 1)
      poke([a, p, b])

      Process.sleep(400)
      refute stopped?(a)
      refute stopped?(p)
      refute switching?(a)
      refute started?(b)
    end

    test "the hold lasts the whole drain; a stop during it is applied at once", %{root: root} do
      env(slice_s: 0)
      HostStub.set_procs(2)
      a = bot(root)
      b = asleep(root)
      msg(b, 1)
      poke([a, b])

      assert eventually(fn -> switching?(a) end)
      {"switching", until} = Webhook.paused(reload(a))
      assert DateTime.diff(until, DateTime.utc_now()) >= 30 * 60 + 300 - 5

      assert :ok = BotManager.stop(a.name, wait: true)
      assert stopped?(a)
      assert {"stopping", _} = Webhook.paused(reload(a))
    end

    test "a restart or a settings save during a drain waits; the hold stays", %{root: root} do
      env(slice_s: 0)
      HostStub.set_procs(2)
      a = bot(root)
      b = asleep(root)
      msg(b, 1)
      poke([a, b])
      assert eventually(fn -> switching?(a) end)

      BotManager.restart(a.name)
      set(a, settings_seq: 5)
      poke(a)
      Process.sleep(300)
      assert starts() == []
      assert switching?(a)

      HostStub.set_procs(1)
      assert eventually(fn -> reload(a).sleeping end)
      assert eventually(fn -> started?(b) end)
      assert hd(starts()) == b.name
    end

    test "the drain waits for a recent delivery, a turn and a call in flight", %{root: root} do
      env(slice_s: 0)
      a = bot(root)
      b = asleep(root)
      msg(b, 1)
      ref = Inflight.enter(a.id)
      poke([a, b])
      assert eventually(fn -> switching?(a) end)

      # Delivered just now (hermes may still buffer it), and a turn running.
      msg(a, 7, acked: 0)
      turns(a, 1)
      Process.sleep(150)
      refute stopped?(a)

      Inflight.leave(ref)
      Process.sleep(150)
      refute stopped?(a)

      turns(a, 0)
      Process.sleep(150)
      refute stopped?(a)

      from(u in Inbox, where: u.instance_id == ^a.id and u.update_id == 7)
      |> Repo.update_all(set: [acked_at: DateTime.add(DateTime.utc_now(), -20)])

      assert eventually(fn -> stopped?(a) end)
      assert eventually(fn -> reload(a).sleeping end)
    end

    test "the drain cap stops the bot and tells the chat that spoke last", %{root: root} do
      telegram()
      env(slice_s: 0, max_drain_s: 1)
      a = bot(root)
      # gateway_state.json unreadable: busy for ever, as today.
      File.rm!(Path.join(Path.dirname(a.workspace), "gateway_state.json"))
      msg(a, 1, ago: 130, acked: 120, chat: 777)
      b = asleep(root)
      msg(b, 1)
      poke([a, b])

      assert eventually(fn -> reload(a).sleeping end, 80)
      assert stopped?(a)
      path = "/botT#{a.id}/sendMessage"
      assert_receive {:telegram, ^path, %{"chat_id" => 777, "text" => text}}, 2_000
      assert text =~ "Задача заняла слишком много времени"
    end

    test "held rows survive a switch and wait for the next wake", %{root: root} do
      env(slice_s: 0)
      HostStub.set_procs(2)
      a = bot(root)
      b = asleep(root)
      msg(b, 1, ago: 60)
      poke([a, b])
      assert eventually(fn -> switching?(a) end)
      # Comes in during the drain: held, never handed over.
      msg(a, 9)
      env(slice_s: 3600)
      HostStub.set_procs(1)

      assert eventually(fn -> reload(a).sleeping end)
      assert is_nil(Repo.get_by!(Inbox, instance_id: a.id, update_id: 9).acked_at)
      refute Webhook.paused(reload(a))
      assert eventually(fn -> started?(b) end)

      # b answers its message (no relay here), then its slice ends: a comes
      # back for its held row, which it has still not been handed.
      from(u in Inbox, where: u.instance_id == ^b.id)
      |> Repo.update_all(set: [acked_at: DateTime.add(DateTime.utc_now(), -120)])

      env(slice_s: 0)
      assert eventually(fn -> started?(a) end)
      assert is_nil(Repo.get_by!(Inbox, instance_id: a.id, update_id: 9).acked_at)
      refute Webhook.paused(reload(a))
    end
  end

  describe "notices" do
    test "one notice per wait, with the place in the line", %{root: root} do
      telegram()
      b0 = blocker(root)
      a = asleep(root)
      b = asleep(root)
      c = asleep(root)
      msg(a, 1, ago: 120)
      msg(b, 1, ago: 90)
      msg(c, 1, ago: 10)
      poke([b0, a, b, c])
      Process.sleep(600)

      assert sent_texts(a) == [{5000 + a.id, "Бот просыпается, ответ скоро придёт."}]

      assert sent_texts(b) == [
               {5000 + b.id,
                "Бот сейчас отвечает другим. Перед вами в очереди: 1. Ответ придёт сам, писать ещё раз не нужно."}
             ]

      assert sent_texts(c) == []
      assert sent_texts(b0) == []

      # A new wait (its oldest row changed) gets a new notice.
      from(u in Inbox, where: u.instance_id == ^a.id)
      |> Repo.update_all(set: [acked_at: DateTime.utc_now()])

      msg(a, 2, ago: 100)
      Process.sleep(300)
      assert [{_, "Бот просыпается, ответ скоро придёт."}] = sent_texts(a)
    end
  end
end
